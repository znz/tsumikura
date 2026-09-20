class AddWebauthnIdToUsers < ActiveRecord::Migration[8.1]
  def change
    # WebAuthn の user handle (base64url)。パスキーの初回登録時に生成する。
    # メールアドレスを user handle にすると認証器に個人情報が残るので、無作為な値を使う
    # (docs/spec/01-domain-model.md / docs/spec/05-auth.md 5 節)
    add_column :users, :webauthn_id, :string, limit: 255
    add_index :users, :webauthn_id, unique: true
  end
end
