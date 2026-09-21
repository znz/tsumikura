class CreateItemAlertStates < ActiveRecord::Migration[8.1]
  def change
    create_table :item_alert_states, id: :uuid, default: -> { "uuidv7()" } do |t|
      # 品目 1 件につき 1 行。品目は物理削除しない (アーカイブする) ので restrict にし、
      # アーカイブ済みの行は日次ジョブが消す (docs/spec/04-notifications.md 4 節)
      t.references :item, type: :uuid, null: false, index: { unique: true },
        foreign_key: { on_delete: :restrict }
      # 前回突き合わせたときのステータス。**文字列**で持つ
      # (docs/spec/02-forecast.md 14 節: Symbol を入れると読み出しで文字列になり、
      #  毎回「変化あり」と判定されて毎朝鳴ってしまう)
      t.string :notified_purchase_status
      t.string :notified_expiry_status
      # 最後に突き合わせた時刻。通知を送らなかった日 (悪化 0 件) も更新する
      t.datetime :notified_at

      t.timestamps
    end
  end
end
