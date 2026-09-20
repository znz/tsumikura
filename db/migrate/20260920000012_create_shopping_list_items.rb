class CreateShoppingListItems < ActiveRecord::Migration[8.1]
  def change
    create_table :shopping_list_items do |t|
      # 買い物リストは「要購入判定からの導出 ∪ 永続行」(docs/spec/01-domain-model.md 判断 5)。
      # このテーブルに入るのは**ユーザーが手を加えたものだけ**で、自動で並ぶ行は書き戻さない。
      #
      # item_id が null の行はマスタにない自由入力 (「はがき」など)。
      # 品目は物理削除しない (アーカイブする) ので on_delete は restrict にし、
      # 万一の物理削除で買い物リストだけが残らないようにする
      t.references :item, foreign_key: { on_delete: :restrict }, index: false
      t.string :free_text                    # item_id が null のとき必須
      t.integer :quantity                    # 手入力の希望数 (null = 推奨数量を使う)
      t.datetime :checked_at                 # null 以外 = チェック済み
      t.date :snoozed_until                  # 「今回は買わない」(この日まで自動で並べない)
      # 「手動で足した行」の目印。判定が ok に戻っても消さないために要る
      # (チェックも数量の上書きも無い行と区別できないため。docs/spec/01-domain-model.md 判断 5)
      t.boolean :added_manually, null: false, default: false
      # 追加した人。ユーザーは物理削除せず deactivated_at で無効化するので restrict でよい
      t.references :added_by, null: false, foreign_key: { to_table: :users, on_delete: :restrict }

      t.timestamps
    end

    # 品目 1 件につき行は 1 つ (チェック操作が来たときに find_or_create_by(item:) する)。
    # 自由入力の行は item_id が null なので、この一意制約の対象から外れる
    add_index :shopping_list_items, :item_id, unique: true, where: "item_id IS NOT NULL"
    # まとめ購入の対象 (チェック済み) を引く
    add_index :shopping_list_items, :checked_at

    # 品目も自由入力も無い行は「何も指していない行」なので DB で止める
    add_check_constraint :shopping_list_items,
      "(item_id IS NOT NULL) OR (free_text IS NOT NULL)",
      name: "shopping_list_items_item_or_free_text"
  end
end
