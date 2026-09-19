class StockTakeEntry < ApplicationRecord
  # 棚卸の明細 (docs/spec/01-domain-model.md 判断 3)。
  # 既定は品目ごとに「実数の合計」だけを入力する行 (lot_id は nil)。
  # 期限を管理していてロットが 2 件以上ある品目だけ、ロット別に数えた行を作れる。
  #
  # counted_quantity が nil = 未入力。確定のときスキップする
  # (docs/spec/03-screens.md 画面 6)。
  # difference は counted - expected の従属値で、フォームからは受け取らない
  # (二重管理のずれは DB の check 制約と rake stock:verify が見張る)。

  # 整数カラムの上限。numericality は 4 バイト整数の範囲を見ないので、上限が無いと
  # 書き込み時に ActiveModel::RangeError になり 422 ではなく 500 になる
  MAX_QUANTITY = Item::MAX_QUANTITY
  # 8 バイト整数の上限。これを超える id を where に渡すと PG が範囲エラーを返して 500 になる
  MAX_ID = 2**63 - 1
  # 「大きく減った」とみなす下限。打ち間違い (12 を 1 と入れるなど) は消費として
  # 予測に残り続けるので、確認画面で注意の印を出す。1 個の減りは日常なので数えない
  LARGE_DECREASE_MINIMUM = 2

  # 確定済みの棚卸の明細は書き換えない。確定 (Stock::FinalizeStockTake) は
  # finalized_at を最後に入れるので、確定の処理自体はここに引っかからない
  class Finalized < StandardError; end

  belongs_to :stock_take
  belongs_to :item
  belongs_to :lot, optional: true                      # ロット別に数えた場合のみ
  # 確定で作られる調整の movement。確定済みの棚卸は削除しない方針なので、
  # 万一 (品目ごと消すなど) に備えて台帳を黙って消さない
  has_many :stock_movements, dependent: :restrict_with_error

  before_validation :apply_difference
  # 確定済みの棚卸に明細を足したり書き換えたりさせない (最後の防壁)。
  # 確定と「途中保存」が同時に走ると、movement は古い差分のままで明細だけが変わり、
  # 「差分 ≠ movements の合計」が残ってしまう
  before_save :ensure_stock_take_not_finalized
  # prepend は必須。dependent: :restrict_with_error より先に判定する
  before_destroy :ensure_stock_take_not_finalized, prepend: true

  validates :expected_quantity,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_QUANTITY }
  validates :counted_quantity,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_QUANTITY },
    allow_nil: true

  validate :lot_must_belong_to_item

  scope :counted, -> { where.not(counted_quantity: nil) }
  scope :increased, -> { where(difference: 1..) }
  scope :decreased, -> { where(difference: ...0) }
  # 画面と確定の処理順。品目ごとにまとまり、合計行 (lot_id が nil) が先に来る
  # (PostgreSQL の ASC は NULL が最後なので、明示的に先頭へ寄せる)
  scope :ordered, -> { order(:item_id, Arel.sql("lot_id ASC NULLS FIRST"), :id) }

  def counted?
    counted_quantity.present?
  end

  # 確定で実際に使われる「今の記録在庫」。数えてから確定までに使用・購入があると、
  # 数えた時点の expected_quantity とは変わる (確認画面はこちらを見せる)
  def current_expected_quantity
    lot ? lot.remaining_quantity : item.current_quantity
  end

  def current_difference
    counted_quantity && counted_quantity - current_expected_quantity
  end

  # 数えたあとに在庫の記録が動いた明細 (確認画面で知らせる)
  def stock_moved_since_counted?
    counted? && current_expected_quantity != expected_quantity
  end

  # 打ち間違いは消費として予測に残り続けるので、大きく減る差分には注意の印を出す。
  # 「記録在庫の半分以上」かつ「LARGE_DECREASE_MINIMUM 以上」減るものを大きいとみなす
  def large_decrease?(difference = self.difference, expected = expected_quantity)
    return false if difference.nil? || !difference.negative?

    difference.abs >= LARGE_DECREASE_MINIMUM && difference.abs * 2 >= expected.to_i
  end

  private
    def apply_difference
      self.difference = counted_quantity.nil? ? nil : counted_quantity - expected_quantity.to_i
    end

    # 品目ごと消すとき (item.destroy) は明細も一緒に消えるので止めない。
    # finalized_at は「DB に入っている値」を見る (確定は明細を直してから最後に
    # finalized_at を入れるので、確定の処理自体は通る)
    def ensure_stock_take_not_finalized
      return if destroyed_by_association
      return if stock_take.nil? || stock_take.finalized_at_in_database.nil?

      raise Finalized, "確定済みの棚卸 ##{stock_take_id} の明細は変更できません"
    end

    # 参照先を引ける id か。8 バイト整数をはみ出す値のまま関連をたどると、
    # クエリが ActiveModel::RangeError になり 422 ではなく 500 になる
    def lot_id_resolvable?
      lot_id.is_a?(Integer) && lot_id.between?(1, MAX_ID)
    end

    # 他の品目のロットは数えられない (DB 側にも複合外部キーがある)
    def lot_must_belong_to_item
      return if lot_id.blank?
      return errors.add(:lot, :invalid) unless lot_id_resolvable?
      return if item_id.blank?

      errors.add(:lot, :mismatched_item) if lot.blank? || lot.item_id != item_id
    end
end
