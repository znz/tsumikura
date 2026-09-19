class ItemPurpose < ApplicationRecord
  # 用途は品目に紐づく子レコード (docs/spec/01-domain-model.md 判断 4)。
  # 購入予測は品目全体の消費ペースで行い、用途は履歴と交換周期の表示専用。
  include Positioned

  MAX_QUANTITY = Item::MAX_QUANTITY

  belongs_to :item
  # 使用記録は履歴なので、用途を消しても道連れにはしない
  # (使用記録が紐づく用途はそもそも削除させず、アーカイブしてもらう)
  has_many :usage_records

  normalizes :name, with: Normalizations::STRIP

  validates :name, presence: true, length: { maximum: 50 },
    uniqueness: { scope: :item_id, case_sensitive: false }
  validates :default_quantity,
    numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_QUANTITY }

  # 履歴を消さないための守り。dependent: :destroy より先に走らせる必要があるので prepend
  before_destroy :ensure_not_used, prepend: true

  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }

  def archived?
    archived_at.present?
  end

  def archive!
    return true if archived?

    update_columns(archived_at: Time.current, updated_at: Time.current)
  end

  # 戻すときは末尾に置く。アーカイブ中に並べ替えが走って position が振り直されているので、
  # 昔の position のまま戻すと一覧の途中に割り込む
  def restore!
    update_columns(archived_at: nil, position: next_position, updated_at: Time.current)
  end

  def used?
    usage_records.exists?
  end

  # 交換周期は同一用途の used_on の差分の中央値 (平均より外れ値に強い。
  # docs/spec/01-domain-model.md 判断 4)。1 件しか無ければ周期は出せない。
  # 同じ日に 2 回記録しても「周期 0 日」にしないよう、日付は重複を除いて数える
  def replacement_interval_days
    dates = used_on_dates
    return nil if dates.size < 2

    self.class.median(dates.each_cons(2).map { |from, to| (to - from).to_i })
  end

  def last_used_on
    used_on_dates.last
  end

  def usage_count
    usage_records.size
  end

  # 中央値。偶数個なら中央 2 つの平均を四捨五入して日数 (整数) にする
  def self.median(values)
    sorted = values.sort
    middle = sorted.size / 2
    return sorted[middle] if sorted.size.odd?

    Rational(sorted[middle - 1] + sorted[middle], 2).round
  end

  private
    # 用途の並べ替えは品目の中だけで閉じる (他の品目の用途とは入れ替えない)。
    # アーカイブ済みは一覧に出ないので範囲に入れない
    # (入れると「上へ」が見えない用途と入れ替わって画面が変わらない)
    def positioned_siblings
      self.class.where(item_id: item_id).active
    end

    # 採番はアーカイブ済みも含めた末尾に置く (戻したときに position が重ならないように)
    def positioned_numbering_scope
      self.class.where(item_id: item_id)
    end

    # includes(:usage_records) で先読みしてあれば追加のクエリを出さない
    def used_on_dates
      usage_records.map(&:used_on).uniq.sort
    end

    def ensure_not_used
      # 品目ごと消すとき (item.destroy) は使用記録も一緒に消えるので止めない
      return if destroyed_by_association
      return unless used?

      errors.add(:base, :used)
      throw(:abort)
    end
end
