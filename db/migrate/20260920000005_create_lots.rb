class CreateLots < ActiveRecord::Migration[8.1]
  def change
    create_table :lots do |t|
      # 1 行 = 1 回の入庫 (docs/spec/01-domain-model.md 判断 2)。
      # 期限のない品目でもロットを作るので expires_on は NULL 可
      t.references :item, null: false, foreign_key: true, index: false
      t.integer :kind, null: false, default: 0                  # 0:purchase 1:initial 2:adjustment
      t.date :acquired_on, null: false                          # 購入日 / 初期在庫日 / 棚卸日
      t.date :expires_on
      t.integer :initial_quantity, null: false                  # 入庫時の数量 (> 0)
      t.integer :remaining_quantity, null: false, default: 0    # キャッシュ: movements の総和
      t.integer :pack_size                                      # 入数 (入力の記録用)
      t.integer :pack_count                                     # パック数
      t.integer :price_yen                                      # 税込合計 (任意)
      # 店舗の削除は nullify。購入記録は消さず店舗だけを外す (docs/spec/01-domain-model.md 3 節)
      t.references :store, foreign_key: { on_delete: :nullify }
      # 記録者。ユーザーは物理削除せず deactivated_at で無効化するので restrict でよい
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      t.text :note
      t.datetime :depleted_at                                   # キャッシュ: 残 0 になった日時

      t.timestamps
    end

    # [item_id] 単独の index は [item_id, expires_on] が兼ねるので張らない
    add_index :lots, [ :item_id, :expires_on ]
    add_index :lots, [ :item_id, :depleted_at ]
    add_index :lots, :expires_on
    # stock_movements の複合外部キー (lot_id, item_id) の参照先。
    # 非正規化した stock_movements.item_id がロットとずれないよう DB 側で保証する
    add_index :lots, [ :id, :item_id ], unique: true

    add_check_constraint :lots, "initial_quantity > 0", name: "lots_initial_quantity_positive"
    add_check_constraint :lots, "remaining_quantity >= 0", name: "lots_remaining_quantity_non_negative"
    # 入数とパック数は「両方あるか、両方 NULL か」。あるなら積が数量と一致する
    # (「入数 × パック数」と「直接入力」のどちらで入れたかを記録として壊さない)
    add_check_constraint :lots, "(pack_size IS NULL) = (pack_count IS NULL)", name: "lots_pack_pair"
    add_check_constraint :lots, "pack_size IS NULL OR pack_size * pack_count = initial_quantity",
      name: "lots_pack_quantity_matches"
  end
end
