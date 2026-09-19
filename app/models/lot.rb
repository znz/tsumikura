class Lot < ApplicationRecord
  # 1 行 = 1 回の入庫。期限のない品目でもロットを作る (docs/spec/01-domain-model.md 判断 2)。
  # remaining_quantity / depleted_at は stock_movements から再計算できるキャッシュで、
  # 値を入れるのは Stock::Recalculator だけ。

  # 整数カラムの上限。numericality は 4 バイト整数の範囲を見ないので、上限が無いと
  # 書き込み時に ActiveModel::RangeError になり 422 ではなく 500 になる
  MAX_QUANTITY = Item::MAX_QUANTITY
  MAX_PACK_COUNT = 999
  MAX_PRICE_YEN = 9_999_999

  # 画面から作れる由来は購入と初期在庫だけ。adjustment は棚卸 (Phase 9) と
  # 在庫不足時の自動補填 (Phase 8) が作るので、画面からは作らせず編集もさせない
  RECORDABLE_KINDS = %w[ purchase initial ].freeze

  # 「最近の単価」に使う、価格のあるロットの件数 (docs/spec/01-domain-model.md 判断 6)
  RECENT_PRICED_LOTS = 5

  # 単価がこの金額より安いと四捨五入で 0 円になってしまうので、小数 1 桁まで出す
  UNIT_PRICE_DECIMAL_THRESHOLD = 10

  belongs_to :item
  belongs_to :store, optional: true
  belongs_to :user                       # 記録者
  has_many :stock_movements, dependent: :destroy

  # prefix は必須。付けないと initial などが AR の予約語・スコープ名と紛らわしくなる。
  # validate: true なので未知の値は例外ではなく検証エラーになる
  enum :kind, { purchase: 0, initial: 1, adjustment: 2 }, prefix: true, validate: true

  # FEFO: 期限が近い順 → 古い購入順。期限 nil はその後、期限切れロットは最後
  # (期限切れから先に引くと、期限切れを除いて数える在庫 q が減らないため)
  scope :fefo, ->(today = Date.current) {
    order(Arel.sql(sanitize_sql_array([ "(expires_on < ?) IS TRUE", today ])),
      Arel.sql("expires_on ASC NULLS LAST"), :acquired_on, :id)
  }
  scope :available, -> { where("remaining_quantity > 0") }
  scope :depleted, -> { where(remaining_quantity: 0) }
  scope :expired, ->(today = Date.current) { where(expires_on: ...today) }
  scope :priced, -> { where.not(price_yen: nil) }
  # 「最近」は購入日の新しい順。同じ日なら後から記録したものを新しいとみなす
  scope :recent_first, -> { order(acquired_on: :desc, id: :desc) }
  scope :recordable, -> { where(kind: RECORDABLE_KINDS) }

  before_validation :apply_pack_quantity
  before_save :clear_unused_pack_input
  # prepend は必須。has_many :stock_movements, dependent: :destroy が先に宣言されているので、
  # 付けないと movement が消えたあとにガードが走り「消費なし」と判定してしまう
  before_destroy :ensure_not_consumed, prepend: true

  validates :acquired_on, presence: true
  validates :initial_quantity,
    numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_QUANTITY }
  # キャッシュ列。Stock::Recalculator 以外からは変えない
  validates :remaining_quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :pack_size,
    numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_QUANTITY },
    allow_nil: true
  validates :pack_count,
    numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_PACK_COUNT },
    allow_nil: true
  validates :price_yen,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_PRICE_YEN },
    allow_nil: true
  # フォームを開いている間に店舗が削除されると、そのままでは外部キー違反 (500) になる。
  # id が 0 のときも弾きたいので store_id? (query_attribute) ではなく present? で判定する
  validates :store, presence: { message: :invalid }, if: -> { store_id.present? }

  validate :acquired_on_cannot_be_in_the_future
  validate :initial_quantity_must_cover_consumption, on: :update

  # 「最近の単価」は、価格のある直近 RECENT_PRICED_LOTS 件の総額 ÷ 総数量
  # (調整ロットの価格 NULL で歪まないように価格のあるロットだけを見る。
  # docs/spec/01-domain-model.md 判断 6)
  def self.average_unit_price_yen(lots)
    recent = lots
      .select { |lot| lot.price_yen.present? && lot.initial_quantity.to_i.positive? }
      .sort_by { |lot| [ lot.acquired_on, lot.id ] }
      .last(RECENT_PRICED_LOTS)
    return nil if recent.empty?

    round_unit_price(Rational(recent.sum(&:price_yen), recent.sum(&:initial_quantity)))
  end

  # 10 円以上は円単位 (Integer)、それより安いものは小数 1 桁 (Float) に丸める。
  # 100 枚 30 円のような品目で単価が 0 円に潰れないようにする
  def self.round_unit_price(price)
    price < UNIT_PRICE_DECIMAL_THRESHOLD ? price.round(1).to_f : price.round
  end

  # 単価は導出する (docs/spec/01-domain-model.md 判断 6)
  def unit_price_yen
    return nil if price_yen.blank? || initial_quantity.to_i <= 0

    self.class.round_unit_price(Rational(price_yen, initial_quantity))
  end

  def depleted?
    depleted_at.present?
  end

  # このロットから出て行った数 (使用・廃棄・マイナスの調整) の絶対値
  def consumed_quantity
    -stock_movements.where(quantity: ...0).sum(:quantity)
  end

  # 出庫の記録が紐づくロットは削除できない (docs/spec/01-domain-model.md 3 節)。
  # 使用・廃棄だけでなく棚卸のマイナス差分 (負の adjustment) も対象にする。
  # 消すと消費ペースの分子・last_consumed_on・確定済み棚卸の記録まで消えてしまうため
  def consumed?
    stock_movements.where(quantity: ...0).exists?
  end

  private
    # 「入数 × パック数」と「直接入力」は JS 無しでも動かす必要があるので、
    # 両方の入力欄がサーバに届く前提で数量を決める。
    # 編集では「触られたほう」を優先する (JS がある環境では、隠れている側の入力欄は
    # 送られてこないので、DB に残った入数 × パック数で数量を上書きしてしまうため)
    def apply_pack_quantity
      self.initial_quantity = pack_size * pack_count if use_pack_quantity?
    end

    # 使わなかった入数・パック数は「入力の記録」としても残さない。
    # 検証エラーのときに入力が消えないよう、消すのは保存の直前にする
    def clear_unused_pack_input
      return if use_pack_quantity?

      self.pack_size = nil
      self.pack_count = nil
    end

    def use_pack_quantity?
      return false if pack_size.blank? || pack_count.blank?

      new_record? || pack_size_changed? || pack_count_changed? || !initial_quantity_changed?
    end

    # 消費イベントが必ず今日以前にあることを予測が前提にしている
    # (docs/spec/01-domain-model.md 2 節 / docs/spec/02-forecast.md)
    def acquired_on_cannot_be_in_the_future
      return if acquired_on.blank?

      errors.add(:acquired_on, :future) if acquired_on > Date.current
    end

    # 編集後の残数が負になる変更は弾く (docs/spec/01-domain-model.md 3 節)
    def initial_quantity_must_cover_consumption
      return if initial_quantity.blank? || !initial_quantity_changed?

      consumed = consumed_quantity
      return if initial_quantity >= consumed

      errors.add(:initial_quantity, :below_consumed, consumed: consumed)
    end

    def ensure_not_consumed
      # 品目ごと消すとき (item.destroy) は movement も一緒に消えるので止めない
      return if destroyed_by_association
      return unless consumed?

      errors.add(:base, :consumed)
      throw(:abort)
    end
end
