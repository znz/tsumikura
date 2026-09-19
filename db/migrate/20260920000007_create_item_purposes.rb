class CreateItemPurposes < ActiveRecord::Migration[8.1]
  def change
    create_table :item_purposes do |t|
      # 用途は品目に紐づく子レコード (docs/spec/01-domain-model.md 判断 4)。
      # グローバルな用途マスタにはしない (「リモコン」は単 3 電池の文脈でのみ意味を持つ)
      t.references :item, null: false, foreign_key: true, index: false
      t.string :name, null: false
      t.integer :default_quantity, null: false, default: 1   # 「リモコンは 2 本」
      t.integer :position, null: false, default: 0
      t.datetime :archived_at                                # 使用記録が残るので物理削除はしない

      t.timestamps
    end

    # 同じ品目の中で用途名は一意。[item_id] 単独の index はこの複合が兼ねる
    add_index :item_purposes, [ :item_id, :name ], unique: true
    # 品目ごとの並び順で引く (Positioned の ordered)
    add_index :item_purposes, [ :item_id, :position ]
    # usage_records の複合外部キー (item_purpose_id, item_id) の参照先。
    # 「他の品目の用途を指す使用記録」を DB 側でも止める (モデルの検証だけに頼らない)
    add_index :item_purposes, [ :id, :item_id ], unique: true

    # 0 本や負の既定数量は使用記録の初期値として意味がない
    # (usage_records.quantity > 0 と足並みをそろえる)
    add_check_constraint :item_purposes, "default_quantity > 0",
      name: "item_purposes_default_quantity_positive"
  end
end
