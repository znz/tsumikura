class CreateItems < ActiveRecord::Migration[8.1]
  def change
    create_table :items, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :name, null: false
      t.string :name_reading                                    # ひらがな検索用 (任意)
      # マスタの削除は nullify (docs/spec/01-domain-model.md 3 節)。
      # モデル側の dependent: :nullify だけでなく DB 側でも保証する
      t.references :category, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :storage_location, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :unit, null: false, default: "個"
      t.integer :default_pack_size                              # 入数の既定値
      t.integer :minimum_quantity                               # 最低在庫数 (任意)
      t.boolean :tracks_expiry, null: false, default: false
      t.boolean :tracks_purposes, null: false, default: false
      t.integer :estimation_mode, null: false, default: 0       # 0:auto 1:manual 2:none
      t.integer :manual_interval_days                           # manual: 1 単位を何日で使うか
      t.integer :soon_threshold_days                            # null = 既定 (config/tsumikura.yml)
      t.integer :urgent_threshold_days                          # null = 既定
      t.integer :expiry_warning_days                            # null = 既定
      t.boolean :favorite, null: false, default: false
      t.datetime :archived_at                                   # 品目は物理削除しない
      t.text :note

      # ここから下は台帳 (stock_movements) から再計算できるキャッシュ列。
      # 値を入れるのは Phase 7 以降の Stock::Recalculator で、フォームからは触らせない
      t.integer :current_quantity, null: false, default: 0
      t.date :tracking_started_on
      t.date :last_consumed_on

      t.timestamps
    end

    add_index :items, :archived_at
    add_index :items, :favorite
    add_index :items, :name
    add_check_constraint :items, "current_quantity >= 0", name: "items_current_quantity_non_negative"
  end
end
