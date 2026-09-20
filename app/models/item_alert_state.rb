# 前回のダイジェストで突き合わせた品目のステータス (docs/spec/04-notifications.md 4 節)。
#
# 「前回通知時より悪化したか」を決めるためだけに持つ。**改善も記録する**ので、
# 回復した品目がもう一度悪化したときにはまた通知される。
# status は Symbol ではなく**文字列**で保存する (docs/spec/02-forecast.md 14 節)。
#
# items のカラムにしないのは、日次ジョブが items を毎日 UPDATE すると updated_at が汚れ、
# 「最近編集した品目」が使えなくなるため (docs/spec/01-domain-model.md 2 節)。
class ItemAlertState < ApplicationRecord
  belongs_to :item

  # 現在値で一括更新する。送信の成否にかかわらず全品目ぶんを書くので upsert_all 1 本にする
  # (品目数ぶんの UPDATE を撃たない)。entries は Notifications::Digest::Entry。
  def self.record!(entries, at: Time.current)
    entries = Array(entries)
    return 0 if entries.empty?

    rows = entries.map do |entry|
      {
        item_id: entry.item_id,
        notified_purchase_status: entry.purchase_status,
        notified_expiry_status: entry.expiry_status,
        notified_at: at
      }
    end

    upsert_all(rows, unique_by: :item_id, record_timestamps: true).length
  end

  # アーカイブ済みの品目の行は残さない (判定にも通知にも使われないため)。
  # 復元されたときは「前回値なし」= unknown / fresh からやり直す
  def self.purge_archived!
    where(item_id: Item.archived.select(:id)).delete_all
  end
end
