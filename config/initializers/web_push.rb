# Web Push (VAPID) の鍵 (docs/spec/04-notifications.md 2 節)。
#
# 鍵は環境変数で渡す (docs/ops/first-deploy.md 3 節)。**秘密鍵はリポジトリにもログにも置かない。**
# 未設定でもアプリは起動する (通知だけが無効になる) ので fetch はしない。
# 読み出しは Vapid モジュール (app/models/vapid.rb) を通す。
Rails.application.config.x.vapid = {
  public_key: ENV["VAPID_PUBLIC_KEY"].presence,
  private_key: ENV["VAPID_PRIVATE_KEY"].presence,
  # subject は "mailto:" か "https:" の連絡先。Push サービスが送信者を問い合わせるために使う
  subject: ENV["VAPID_SUBJECT"].presence || "mailto:admin@example.com"
}
