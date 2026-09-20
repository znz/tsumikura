# VAPID 鍵 (docs/spec/04-notifications.md 2 節) の読み出し口。
#
# 値そのものは config/initializers/web_push.rb が環境変数から config.x.vapid に入れる。
# 鍵が設定されていない環境 (開発・test・鍵を入れる前の本番) では configured? が false になり、
# 画面は通知セクションを案内だけにし、配信ジョブは何もせずに終わる。
#
# **秘密鍵をログや例外メッセージに出さない**ため、この口以外から config.x.vapid を読まない。
module Vapid
  module_function

  # WebPush.payload_send の vapid: にそのまま渡せるハッシュ
  def keys
    Rails.application.config.x.vapid || {}
  end

  # ブラウザの pushManager.subscribe に渡す applicationServerKey (base64url)
  def public_key
    keys[:public_key]
  end

  def configured?
    keys[:public_key].present? && keys[:private_key].present?
  end
end
