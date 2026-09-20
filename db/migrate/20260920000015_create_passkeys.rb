class CreatePasskeys < ActiveRecord::Migration[8.1]
  def change
    create_table :passkeys do |t|
      # ユーザーは物理削除しない (deactivated_at で無効化する) ので restrict でよい。
      # 無効化してもパスキーは消さない (無効化は取り消せるため)。
      # ログイン側が User.active で落とす (docs/spec/05-auth.md 5 節)
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      # 認証器が払い出す credential ID (base64url)。**認証時はこれだけで行を引く**ので一意にする。
      # 長さは仕様上 1023 バイトまで許されるが、base64url で 1400 文字あれば足りる
      t.string :external_id, null: false, limit: 1400
      # COSE 形式の公開鍵 (base64)。秘密は含まないが、ログには出さない
      # (config/initializers/filter_parameter_logging.rb の :_key / :credential)
      t.text :public_key, null: false
      # 認証器の署名カウンタ。クローン検知に使う。
      # 同期型のパスキー (iCloud / Google) は常に 0 を返すので、0 のままでも正常
      t.bigint :sign_count, null: false, default: 0
      # 「太郎のiPhone」。家族が一覧でどの端末か分かるようにする
      t.string :nickname, null: false, limit: 50
      t.datetime :last_used_at

      t.timestamps
    end

    add_index :passkeys, :external_id, unique: true
  end
end
