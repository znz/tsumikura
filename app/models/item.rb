class Item < ApplicationRecord
  # 単位はマスタを作らず自由入力にする。よく使うものだけフォームの datalist で候補に出す
  # (docs/spec/03-screens.md)
  UNIT_SUGGESTIONS = %w[ 個 本 ロール 袋 パック 箱 枚 セット ].freeze

  # 整数カラムの上限。numericality は 4 バイト整数の範囲を見ないので、上限が無いと
  # 書き込み時に ActiveModel::RangeError になり 422 ではなく 500 になる
  MAX_QUANTITY = 99_999
  MAX_DAYS = 3_650

  belongs_to :category, optional: true
  belongs_to :storage_location, optional: true

  # 品目は物理削除しない (アーカイブする) が、消したときに在庫の記録だけが残らないようにする。
  # stock_movements を先に宣言するのは、ロットより先に movement を消すため
  # (逆だと Lot#ensure_not_consumed に止められて中途半端に壊れる)
  has_many :stock_movements, dependent: :destroy
  has_many :lots, dependent: :destroy

  # prefix は必須。付けないと none が AR の Item.none (空スコープ) と衝突し、
  # Rails がクラスロード時に ArgumentError を出す。
  # validate: true なので未知の値は例外ではなく検証エラーになる。
  # Forecast には estimation_mode.to_sym で渡す (Forecast::Pace は文字列を受け付けない)
  enum :estimation_mode, { auto: 0, manual: 1, none: 2 }, prefix: true, validate: true

  normalizes :name, :unit, with: Normalizations::STRIP
  normalizes :name_reading, with: Normalizations::READING

  validates :name, presence: true, length: { maximum: 50 }
  validates :name_reading, length: { maximum: 100 }
  validates :unit, presence: true, length: { maximum: 20 }
  validates :default_pack_size,
    numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_QUANTITY },
    allow_nil: true
  validates :minimum_quantity,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_QUANTITY },
    allow_nil: true
  # 0 や負の間隔からはペースを出せない (docs/spec/02-forecast.md 8 節)
  validates :manual_interval_days,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: MAX_DAYS },
    allow_nil: true
  # 「手動」を選んで間隔が空だと予測が永久に unknown になり、auto より悪い状態に黙って落ちる。
  # Forecast::Pace 側の「nil なら unknown」は防御として残す (docs/spec/02-forecast.md 8 節)
  validates :manual_interval_days, presence: true, if: :estimation_mode_manual?
  validates :soon_threshold_days, :urgent_threshold_days, :expiry_warning_days,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_DAYS },
    allow_nil: true
  # キャッシュ列。Stock::Recalculator (Phase 7) 以外からは変えない
  validates :current_quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # フォームを開いている間にマスタが削除されると、保存時に外部キー違反 (500) になる。
  # id が 0 のときも弾きたいので category_id? (query_attribute) ではなく present? で判定する
  validates :category, presence: { message: :invalid }, if: -> { category_id.present? }
  validates :storage_location, presence: { message: :invalid }, if: -> { storage_location_id.present? }

  validate :urgent_threshold_must_not_exceed_soon_threshold

  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }
  # 漢字の名前をコードポイント順に並べても五十音順にならないので、よみがあれば優先する
  scope :ordered, -> { order(Arel.sql("COALESCE(items.name_reading, items.name)"), :id) }

  # 名前とよみの部分一致。LIKE のワイルドカード (% _ \) は検索語の一部として扱う。
  # よみはひらがなで保存しているので、検索語もひらがなにそろえて比べる
  scope :search, ->(query) {
    query = Normalizations::STRIP.call(query.to_s)
    next all if query.empty?

    name_pattern = "%#{Item.sanitize_sql_like(query)}%"
    reading_pattern = "%#{Item.sanitize_sql_like(Normalizations::TO_HIRAGANA.call(query))}%"
    where("items.name ILIKE :name OR items.name_reading ILIKE :reading",
      name: name_pattern, reading: reading_pattern)
  }
  scope :in_category, ->(category_id) {
    category_id.present? ? where(category_id: category_id) : all
  }
  scope :in_storage_location, ->(storage_location_id) {
    storage_location_id.present? ? where(storage_location_id: storage_location_id) : all
  }

  def self.default_expiry_warning_days
    Rails.configuration.x.tsumikura.dig(:expiry, :warning_days)
  end

  def archived?
    archived_at.present?
  end

  # 品目は物理削除しない (docs/spec/01-domain-model.md 3 節)。
  # 既定の閾値を変えたあとなどに保存済みの品目が invalid になることがあるので、
  # アーカイブ / 復元はバリデーションを通さない (直せなくなる方が困る)
  def archive!
    return true if archived?

    update_columns(archived_at: Time.current, updated_at: Time.current)
  end

  def restore!
    update_columns(archived_at: nil, updated_at: Time.current)
  end

  def effective_soon_threshold_days
    soon_threshold_days || Forecast::Thresholds.default.soon_days
  end

  def effective_urgent_threshold_days
    urgent_threshold_days || Forecast::Thresholds.default.urgent_days
  end

  def effective_expiry_warning_days
    expiry_warning_days || self.class.default_expiry_warning_days
  end

  private
    # 「購入推奨」は「そろそろ購入」より手前でなければ意味がない (docs/spec/02-forecast.md 6 節)。
    # 片方だけ上書きされることがあるので、既定値と合成したあとの値で比べ、
    # 何と比べて駄目なのかが分かるよう両方の実効値を文面に入れる
    def urgent_threshold_must_not_exceed_soon_threshold
      return if errors[:soon_threshold_days].any? || errors[:urgent_threshold_days].any?
      return if effective_urgent_threshold_days <= effective_soon_threshold_days

      errors.add(:urgent_threshold_days, :greater_than_soon,
        urgent: effective_urgent_threshold_days, soon: effective_soon_threshold_days)
    end
end
