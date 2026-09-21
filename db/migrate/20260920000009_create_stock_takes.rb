class CreateStockTakes < ActiveRecord::Migration[8.1]
  def change
    create_table :stock_takes, id: :uuid, default: -> { "uuidv7()" } do |t|
      # 棚卸ヘッダ (docs/spec/01-domain-model.md 判断 3)。
      # 保管場所を選んで一括で数え、最後にまとめて確定する。
      # 下書き (finalized_at IS NULL) の間は在庫にいっさい影響しない
      t.date :counted_on, null: false
      # null = 全体。マスタの削除は nullify (docs/spec/01-domain-model.md 3 節)
      t.references :storage_location, type: :uuid, foreign_key: { on_delete: :nullify }, index: false
      # 記録者。ユーザーは物理削除せず deactivated_at で無効化する
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :restrict }
      t.text :note
      t.datetime :finalized_at   # null = 下書き (在庫に未反映)

      t.timestamps
    end

    add_index :stock_takes, :counted_on
    add_index :stock_takes, :finalized_at
    # [storage_location_id] 単独の index はこの複合が兼ねる
    add_index :stock_takes, [ :storage_location_id, :counted_on ]
  end
end
