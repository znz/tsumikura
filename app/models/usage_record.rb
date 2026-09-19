class UsageRecord < ApplicationRecord
  # ユーザーの「使った」操作 1 回 (docs/spec/01-domain-model.md 2 節)。
  # 実際に在庫を動かすのは stock_movements で、FEFO の引き当てで複数行に分かれることがある。
  # quantity は「操作 1 回の数量」で、紐づく負の movement の合計と一致していなければならない
  # (ずれは rake stock:verify が検出する)。

  # 整数カラムの上限。numericality は 4 バイト整数の範囲を見ないので、上限が無いと
  # 書き込み時に ActiveModel::RangeError になり 422 ではなく 500 になる
  MAX_QUANTITY = Item::MAX_QUANTITY
  # 8 バイト整数の上限。これを超える id を where に渡すと PG が範囲エラーを返して 500 になる
  MAX_ID = 2**63 - 1
  # 数量を空で送られたときの既定 (用途を選んでいればその用途の既定数量を使う)
  DEFAULT_QUANTITY = 1

  belongs_to :item
  belongs_to :item_purpose, optional: true
  belongs_to :user                                       # 記録者
  has_many :stock_movements, dependent: :destroy         # 1..n (FEFO で分割)

  # 引き当てるロットの手動指定 (期限を管理する品目のみ)。既定は FEFO の自動引き当てなので
  # DB には持たず、引き当て結果は stock_movements に残る (docs/spec/03-screens.md 画面 4)
  attr_accessor :lot_id
  # 在庫不足を補填した数 (フラッシュの「n 個を調整しました」用)。DB には持たない
  attr_accessor :compensated_quantity
  # 手動で指定したロットが使い切られていて、別のロットから引いたかどうか。DB には持たない
  attr_accessor :preferred_lot_unavailable

  # 「リモコンは 2 本」を JS 無しでも効かせる。数量を空で送られたら、選んだ用途の
  # 既定数量 (用途なしなら 1) で補う (docs/spec/03-screens.md 画面 4)
  before_validation :apply_default_quantity

  validates :quantity,
    numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_QUANTITY }
  validates :used_on, presence: true
  # フォームを開いている間に用途が削除されると、そのままでは外部キー違反 (500) になる。
  # id が 0 のときも弾きたいので item_purpose_id? ではなく present? で判定する
  validates :item_purpose, presence: { message: :invalid }, if: :item_purpose_id_resolvable?

  validate :used_on_cannot_be_in_the_future
  validate :item_purpose_id_must_be_resolvable
  validate :item_purpose_must_belong_to_item
  validate :lot_must_belong_to_item

  # 新しい記録から順に。同じ日なら後から記録したものを新しいとみなす
  scope :recent_first, -> { order(used_on: :desc, id: :desc) }

  # 「最近の記録」で購入 (Lot) と時系列に混ぜるための共通の日付
  def recorded_on
    used_on
  end

  # 手動で指定された引き当て先ロットの id。指定が無ければ nil (FEFO の自動引き当て)。
  # この品目のロットでなければ nil を返し、検証エラーにする
  def selected_lot_id
    id = Integer(lot_id.to_s, 10, exception: false)
    id if id&.between?(1, MAX_ID) && item&.lots&.exists?(id: id)
  end

  private
    # 数量を空で送られたときだけ補う (0 や負は入力の誤りとして検証エラーにする)
    def apply_default_quantity
      return if quantity.present?

      self.quantity = purpose_default_quantity || DEFAULT_QUANTITY
    end

    def purpose_default_quantity
      return nil unless item_purpose_id_resolvable?

      item_purpose&.default_quantity
    end

    # 参照先を引ける id か。8 バイト整数をはみ出す値のまま関連をたどると、
    # クエリが ActiveModel::RangeError になり 422 ではなく 500 になる
    def item_purpose_id_resolvable?
      item_purpose_id.is_a?(Integer) && item_purpose_id.between?(1, MAX_ID)
    end

    def item_purpose_id_must_be_resolvable
      return if item_purpose_id.blank? || item_purpose_id_resolvable?

      errors.add(:item_purpose, :invalid)
    end

    # 消費イベントが必ず今日以前にあることを予測が前提にしている
    # (docs/spec/01-domain-model.md 2 節 / docs/spec/02-forecast.md)
    def used_on_cannot_be_in_the_future
      return if used_on.blank?

      errors.add(:used_on, :future) if used_on > Date.current
    end

    # 他の品目の用途を指定できないようにする (フォームの改ざん・古い画面からの保存)
    def item_purpose_must_belong_to_item
      return unless item_purpose_id_resolvable?
      return if item_purpose.blank? || item_id.blank?

      errors.add(:item_purpose, :mismatched_item) if item_purpose.item_id != item_id
    end

    # 引き当て先のロットも同じ品目のものだけ。黙って FEFO に倒すと、
    # ユーザーが選んだつもりのロットと違うロットから引かれてしまう
    def lot_must_belong_to_item
      return if lot_id.blank?

      errors.add(:lot_id, :invalid) if selected_lot_id.nil?
    end
end
