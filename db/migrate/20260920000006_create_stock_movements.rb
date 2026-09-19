class CreateStockMovements < ActiveRecord::Migration[8.1]
  def change
    create_table :stock_movements do |t|
      # 在庫の唯一の真実 (docs/spec/01-domain-model.md 判断 1)。
      # lots.remaining_quantity / items.current_quantity はここから再計算できるキャッシュ
      t.references :item, null: false, foreign_key: true, index: false  # 集計用の非正規化
      # 外部キーは (lot_id, item_id) の複合で張る (下の add_foreign_key)。
      # 単独の lot_id の外部キーは複合側が兼ねるので作らない
      t.references :lot, null: false, foreign_key: false
      t.integer :kind, null: false             # 0:purchase 1:usage 2:adjustment 3:disposal
      t.integer :quantity, null: false         # 符号付き。入庫は正、使用・廃棄は負
      t.date :occurred_on, null: false
      # 参照先のテーブルは Phase 8 (usage_records) / Phase 9 (stock_take_entries) で作る。
      # ここでは列と index だけ用意し、外部キーはそれぞれのフェーズの migration で add_foreign_key する
      t.bigint :usage_record_id
      t.bigint :stock_take_entry_id
      t.integer :disposal_reason               # kind=disposal のみ: 0:expired 1:damaged 2:lost 3:other
      # 記録者。ユーザーは物理削除しない (docs/spec/01-domain-model.md 3 節)
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      t.text :note

      t.timestamps
    end

    # [item_id] 単独の index は [item_id, occurred_on] が兼ねるので張らない
    add_index :stock_movements, [ :item_id, :occurred_on ]
    add_index :stock_movements, :usage_record_id
    add_index :stock_movements, :stock_take_entry_id
    add_index :stock_movements, [ :kind, :occurred_on ]

    # 集計用に非正規化した item_id が、ロットの品目とずれないようにする。
    # ずれた行は再計算 (where(item_id:).group(:lot_id)) からも検査からも黙って落ちるので、
    # モデルの検証だけでなく DB 側でも止める
    add_foreign_key :stock_movements, :lots, column: [ :lot_id, :item_id ], primary_key: [ :id, :item_id ]

    add_check_constraint :stock_movements, "quantity <> 0", name: "stock_movements_quantity_not_zero"
    # 符号と kind の対応 (0:purchase は正、1:usage / 3:disposal は負、2:adjustment は両方)
    add_check_constraint :stock_movements,
      "(kind = 0 AND quantity > 0) OR (kind IN (1, 3) AND quantity < 0) OR kind = 2",
      name: "stock_movements_quantity_sign_matches_kind"
    # 廃棄理由は廃棄の記録にだけ入る
    add_check_constraint :stock_movements, "disposal_reason IS NULL OR kind = 3",
      name: "stock_movements_disposal_reason_only_for_disposal"
  end
end
