class CreateStockTakeEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :stock_take_entries, id: :uuid, default: -> { "uuidv7()" } do |t|
      # 棚卸明細 (docs/spec/01-domain-model.md 判断 3)。
      # 既定は品目ごとに「実数の合計」を 1 行。tracks_expiry でロットが 2 件以上ある品目だけ、
      # ロット別に数えた行 (lot_id あり) を作れる
      t.references :stock_take, type: :uuid, null: false, foreign_key: true, index: false
      t.references :item, type: :uuid, null: false, foreign_key: true, index: false
      # ロット別に数えた場合のみ。外部キーは (lot_id, item_id) の複合で張る (下の add_foreign_key)
      t.uuid :lot_id
      t.integer :expected_quantity, null: false, default: 0   # 確定時点の記録在庫
      # 実数。NULL = 未入力で、確定のときスキップする
      # (docs/spec/03-screens.md 画面 6「未入力はスキップ」)
      t.integer :counted_quantity
      t.integer :difference                                   # counted - expected (未入力なら NULL)

      t.timestamps
    end

    # 同じ棚卸の中で「品目の合計」は 1 行、「品目 × ロット」も 1 行。
    # PostgreSQL の UNIQUE は NULL 同士を別物として扱うので、合計行 (lot_id IS NULL) は
    # 部分 index で別に守る (NULLS NOT DISTINCT は PostgreSQL 15 以降なので使わない)
    add_index :stock_take_entries, [ :stock_take_id, :item_id, :lot_id ],
      unique: true, where: "lot_id IS NOT NULL",
      name: "index_stock_take_entries_on_take_and_item_and_lot"
    add_index :stock_take_entries, [ :stock_take_id, :item_id ],
      unique: true, where: "lot_id IS NULL",
      name: "index_stock_take_entries_on_take_and_item_total"
    # 部分 index は「合計行だけ」「ロット別だけ」しか使えないので、
    # ヘッダから明細を引くとき (画面・確定・ヘッダ削除時の外部キー検査) 用に単独でも張る
    add_index :stock_take_entries, :stock_take_id
    add_index :stock_take_entries, :item_id
    add_index :stock_take_entries, :lot_id
    # stock_movements の複合外部キー (stock_take_entry_id, item_id) の参照先
    add_index :stock_take_entries, [ :id, :item_id ], unique: true

    add_check_constraint :stock_take_entries, "expected_quantity >= 0",
      name: "stock_take_entries_expected_not_negative"
    add_check_constraint :stock_take_entries, "counted_quantity IS NULL OR counted_quantity >= 0",
      name: "stock_take_entries_counted_not_negative"
    # difference は counted と expected の従属値。二重管理のずれを DB でも止める
    # (未入力なら difference も NULL)
    add_check_constraint :stock_take_entries,
      "(counted_quantity IS NULL AND difference IS NULL) OR " \
      "(counted_quantity IS NOT NULL AND difference = counted_quantity - expected_quantity)",
      name: "stock_take_entries_difference_matches"

    # ロット別に数えた行が、他の品目のロットを指せないようにする
    # (MATCH SIMPLE なので lot_id が NULL の合計行は対象外)
    add_foreign_key :stock_take_entries, :lots,
      column: [ :lot_id, :item_id ], primary_key: [ :id, :item_id ]

    # Phase 7 で列と index だけ作っておいた参照 (docs/spec/01-domain-model.md 2 節)。
    # usage_record_id と同じく複合にして、非正規化した item_id が明細とずれないようにする。
    # on_delete は付けない (既定の NO ACTION)。確定済みの棚卸は削除しない方針だが、
    # DB 側で黙って cascade させると台帳だけが消えてキャッシュがずれる
    add_foreign_key :stock_movements, :stock_take_entries,
      column: [ :stock_take_entry_id, :item_id ], primary_key: [ :id, :item_id ]
  end
end
