class ShoppingListItem < ApplicationRecord
  # 買い物リストで**ユーザーが手を加えたものだけ**を持つ行 (docs/spec/01-domain-model.md 判断 5)。
  # 要購入判定から自動で並ぶ行はここに書き戻さない (GET に副作用を出さない)。
  # チェック・数量の上書き・スヌーズ・手動追加のどれかが来たときに
  # find_or_create_by(item:) で初めて作られる。

  # 自由入力の長さ。買い物メモなので品目名 (Item は 50) と同じ上限にそろえる
  MAX_FREE_TEXT_LENGTH = 50
  MAX_QUANTITY = Item::MAX_QUANTITY
  # 「今回は買わない」で見送る日数。この日数のあいだ自動セクションに並べない
  SNOOZE_DAYS = 7

  # 自由入力の行は品目を持たない
  belongs_to :item, optional: true
  belongs_to :added_by, class_name: "User"

  normalizes :free_text, with: Normalizations::STRIP

  scope :checked, -> { where.not(checked_at: nil) }
  scope :for_items, -> { where.not(item_id: nil) }
  scope :free_text_entries, -> { where(item_id: nil) }
  # ユーザーの意図が何も残っていない品目の行 (掃除してよい行)。
  # 自動で並ぶ品目は導出から出るので、消しても一覧からは消えない。
  # 条件を SQL に置くのは、読んだあとに他の人が付けたチェックごと消さないため
  # (Phase 12 の掃除ジョブもこのスコープを使う)
  scope :blank_for_items, ->(today = Date.current) {
    # snoozed_until が NULL の行も対象にするので、範囲ではなく OR を明示する
    # (NULL < today は NULL になり、範囲条件では引っかからない)
    for_items.where(added_manually: false, checked_at: nil, quantity: nil)
      .where("snoozed_until IS NULL OR snoozed_until < ?", today)
  }

  before_validation :clear_free_text_for_item

  validates :free_text, presence: true, unless: :for_item?
  # presence と numericality / length は別の validates にする
  # (1 つにまとめると allow_nil が presence にも掛かる)
  validates :free_text, length: { maximum: MAX_FREE_TEXT_LENGTH }
  validates :quantity,
    numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_QUANTITY },
    allow_nil: true
  # 品目 1 件につき行は 1 つ (DB 側は item_id IS NOT NULL の部分一意 index)
  validates :item_id, uniqueness: true, allow_nil: true
  # 画面を開いている間に品目が消えた場合に外部キー違反 (500) にしない
  validates :item, presence: { message: :invalid }, if: -> { item_id_before_type_cast.present? }

  # 期限切れのスヌーズや、アーカイブ済み品目の行の掃除 (docs/spec/01-domain-model.md 判断 5)。
  # GET では行を触らないので、まとめ購入の成功時に呼ぶ (日次ジョブは Phase 12 に申し送り)
  def self.purge_stale!(today = Date.current)
    archived = where(item_id: Item.archived.select(:id))

    archived.or(blank_for_items(today)).delete_all
  end

  # 購入を記録したら、その品目の行は役目を終える (docs/spec/01-domain-model.md 判断 5)。
  # チェックも数量の上書きも手動追加の印もスヌーズも、すべて「買う前の意思表示」なので
  # まとめて片づける。残すと、数か月後にまた urgent に戻ったときに古い上書きが復活する
  def self.settle_after_purchase!(item)
    for_items.where(item_id: item.id).delete_all
  end

  # 品目を指している行か (指していなければ自由入力の行)。
  # **item_id だけを見ない**。belongs_to に未保存の Item を入れた状態 (関連はあるが item_id は
  # まだ nil) は保存の直前に親が保存されて item_id が入るので、検証の時点で
  # 「品目が無い = 自由入力」と決めつけると、自由入力を求めるエラーが出てしまう
  def for_item?
    item_id.present? || item.present?
  end

  def checked?
    checked_at.present?
  end

  # 「今回は買わない」。当日 (snoozed_until == today) はまだ見送り、翌日から戻る
  def snoozed?(today = Date.current)
    snoozed_until.present? && snoozed_until >= today
  end

  def display_name
    item&.name || free_text
  end

  private
    # 品目を選んだ行に自由入力は残さない (どちらを表示するかで迷わないように)
    def clear_free_text_for_item
      self.free_text = nil if for_item?
    end
end
