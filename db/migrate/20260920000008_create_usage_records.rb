class CreateUsageRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :usage_records, id: :uuid, default: -> { "uuidv7()" } do |t|
      # ユーザーの「使った」操作 1 回 (docs/spec/01-domain-model.md 2 節)。
      # FEFO で複数ロットに分かれると stock_movements は複数行になるが、記録は 1 行のまま
      t.references :item, type: :uuid, null: false, foreign_key: true, index: false
      # 用途を使わない品目では NULL。外部キーは (item_purpose_id, item_id) の複合で張る
      # (下の add_foreign_key)。単独の外部キーは複合側が兼ねるので作らない
      t.references :item_purpose, type: :uuid, foreign_key: false, index: false
      t.integer :quantity, null: false                       # > 0 (符号は stock_movements 側で付ける)
      t.date :used_on, null: false
      # 記録者。ユーザーは物理削除せず deactivated_at で無効化する
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :restrict }
      t.text :note

      t.timestamps
    end

    # [item_id] / [item_purpose_id] 単独の index はそれぞれの複合が兼ねる
    add_index :usage_records, [ :item_id, :used_on ]
    add_index :usage_records, [ :item_purpose_id, :used_on ]
    add_index :usage_records, :used_on
    # stock_movements の複合外部キー (usage_record_id, item_id) の参照先
    add_index :usage_records, [ :id, :item_id ], unique: true

    add_check_constraint :usage_records, "quantity > 0", name: "usage_records_quantity_positive"

    # 用途は履歴を失わせないよう restrict。同時に「他の品目の用途は指せない」ことも
    # 複合外部キーで保証する (MATCH SIMPLE なので item_purpose_id が NULL の行は対象外)
    add_foreign_key :usage_records, :item_purposes,
      column: [ :item_purpose_id, :item_id ], primary_key: [ :id, :item_id ], on_delete: :restrict

    # Phase 7 で列と index だけ作っておいた参照 (docs/spec/01-domain-model.md 2 節)。
    # (lot_id, item_id) と同じく複合にして、非正規化した item_id が使用記録とずれないようにする
    # (ずれると別の品目のキャッシュが古いまま残る)。
    # on_delete は付けない (既定の NO ACTION)。使用記録を消すときは必ず
    # Stock::DeleteMovement が movement を先に消してキャッシュを再計算するので、
    # DB 側で黙って cascade させると台帳だけが消えてキャッシュがずれる
    add_foreign_key :stock_movements, :usage_records,
      column: [ :usage_record_id, :item_id ], primary_key: [ :id, :item_id ]
  end
end
