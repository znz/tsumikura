class CreateWebPushSubscriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :web_push_subscriptions do |t|
      # ユーザーは物理削除しない (deactivated_at で無効化する) ので restrict でよい。
      # 無効化しても購読は消さない (無効化は取り消せるため)。配信側が User.active で落とす
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      # Push サービスが払い出す URL。**端末 + ブラウザに 1 つ**なので一意にする。
      # 同じ端末で別の家族がログインして購読し直したら user_id を付け替える
      # (docs/spec/04-notifications.md 3 節)。通常は 200-500 バイト
      t.string :endpoint, null: false, limit: 2048
      # 購読の公開鍵 (65 バイト) と認証シークレット (16 バイト) の base64url。
      # どちらも端末を特定できる値なので、ログには出さない (config/initializers/filter_parameter_logging.rb)
      t.string :p256dh_key, null: false, limit: 255
      t.string :auth_key, null: false, limit: 255
      t.string :user_agent, limit: 255  # 画面の「登録済みの端末」の見出しに使う
      t.datetime :last_delivered_at
      t.integer :failure_count, null: false, default: 0

      t.timestamps
    end

    add_index :web_push_subscriptions, :endpoint, unique: true

    # Push サービスの endpoint は必ず https。アプリ側の検証だけに頼らず DB でも止める
    # (http:// や別スキームの URL を入れられると、配信ジョブが任意のホストを叩きに行く)
    add_check_constraint :web_push_subscriptions,
      "endpoint LIKE 'https://%'",
      name: "web_push_subscriptions_https_endpoint"
  end
end
