class StockTake < ApplicationRecord
  # 棚卸のヘッダ (docs/spec/01-domain-model.md 判断 3)。
  # 保管場所を選んで一括で数え、最後にまとめて確定する。
  # 下書き (finalized_at が nil) の間は在庫にいっさい影響せず、
  # 在庫を動かすのは Stock::FinalizeStockTake だけ。

  belongs_to :storage_location, optional: true   # nil = 全体
  belongs_to :user                               # 記録者
  has_many :stock_take_entries, dependent: :destroy

  validates :counted_on, presence: true
  # フォームを開いている間に保管場所が削除されると、そのままでは外部キー違反 (500) になる。
  # id が 0 のときも弾きたいので storage_location_id? ではなく present? で判定する
  validates :storage_location, presence: { message: :invalid },
    if: -> { storage_location_id_before_type_cast.present? }

  validate :counted_on_cannot_be_in_the_future

  # 確定済みは削除しない (docs/spec/01-domain-model.md 3 節)。
  # prepend は必須。has_many :stock_take_entries, dependent: :destroy が先に宣言されているので、
  # 付けないと明細が消えたあとにガードが走る
  before_destroy :ensure_not_finalized, prepend: true

  scope :drafts, -> { where(finalized_at: nil) }
  scope :finalized, -> { where.not(finalized_at: nil) }
  # 新しい棚卸から順に。同じ日なら後から作ったものを新しいとみなす
  scope :recent_first, -> { order(counted_on: :desc, created_at: :desc, id: :desc) }

  def finalized?
    finalized_at.present?
  end

  # 数える対象の品目。保管場所を指定していればその場所だけに絞る。
  # アーカイブ済みは日々の導線から外す方針なので並べない
  def target_items
    scope = Item.active
    scope = scope.where(storage_location_id: storage_location_id) if storage_location_id.present?
    scope.ordered
  end

  # 実数を入力した明細だけ (未入力は確定でスキップする)
  def counted_entries
    stock_take_entries.counted
  end

  def increased_entries
    stock_take_entries.increased
  end

  def decreased_entries
    stock_take_entries.decreased
  end

  def storage_location_name
    storage_location&.name || "すべての保管場所"
  end

  private
    # 消費イベントが必ず今日以前にあることを予測が前提にしている
    # (docs/spec/01-domain-model.md 2 節 / docs/spec/02-forecast.md)
    def counted_on_cannot_be_in_the_future
      return if counted_on.blank?

      errors.add(:counted_on, :future) if counted_on > Date.current
    end

    def ensure_not_finalized
      return unless finalized?

      errors.add(:base, :finalized)
      throw(:abort)
    end
end
