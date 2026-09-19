class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
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
