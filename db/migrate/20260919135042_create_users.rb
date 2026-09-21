class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    # アプリのテーブルの主キーは UUIDv7 (docs/spec/01-domain-model.md 1 節)。
    # 連番だと URL から件数や他のレコードを推測できてしまうため。
    # 生成は PostgreSQL 18 のネイティブ関数 uuidv7() に任せる
    # (Ruby 側で振らないので insert_all / upsert_all でも同じ規則になる)。
    # Solid Queue / Solid Cache のテーブルは bigint のまま (id が外に出ない)
    create_table :users, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :email_address, null: false
      t.string :password_digest, null: false
      t.string :name, null: false
      t.integer :role, null: false, default: 0   # 0: member, 1: admin
      t.boolean :notify_purchases, null: false, default: true
      t.boolean :notify_expiries, null: false, default: true
      t.datetime :deactivated_at                 # 無効化 (ユーザーは削除しない)

      t.timestamps
    end
    add_index :users, :email_address, unique: true
  end
end
