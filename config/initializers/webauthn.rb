require_relative "../../lib/webauthn_origin"

# パスキー (WebAuthn) の設定 (docs/spec/05-auth.md 5 節)。
#
# origin は **スキーム + ホスト + (非標準ポート)**、RP ID は **ホスト名のみ**。
# **RP ID を変えると登録済みのパスキーはすべて使えなくなる**ので、ドメインは後から変えない。
#
# 未設定でもアプリは起動する (パスキーだけが使えなくなる)。VAPID と同じ方針で fetch はしない。
# 読み出しは Passkey.available? を通す (app/models/passkey.rb)。
webauthn_origin =
  ENV["WEBAUTHN_ORIGIN"].presence ||
  if Rails.env.production?
    # WEBAUTHN_ORIGIN を設定し忘れても、同じホストで HTTPS を張っている前提で APP_HOST から導く。
    # 非標準ポートや別ドメインで公開する場合だけ WEBAUTHN_ORIGIN を明示する
    "https://#{ENV["APP_HOST"]}" if ENV["APP_HOST"].present?
  elsif Rails.env.test?
    # request spec の既定ホスト。spec/support/webauthn_helper.rb の FakeClient と合わせる
    "http://www.example.com"
  else
    # localhost は Secure Context 扱いなので HTTPS なしでパスキーを試せる
    "http://localhost:3000"
  end

# 末尾スラッシュ・パス・空白を落とす。正規化できない値は nil にして
# 「パスキーだけが無効」にする (例外を投げるとアプリが起動しなくなる)
normalized_origin = WebauthnOrigin.normalize(webauthn_origin)

if webauthn_origin.present? && normalized_origin.nil?
  Rails.logger&.warn(
    "WEBAUTHN_ORIGIN の値を origin として解釈できませんでした。パスキーは無効になります " \
    "(スキーム + ホスト名の形にしてください。例: https://tsumikura.example.com)"
  )
end

webauthn_rp_id = ENV["WEBAUTHN_RP_ID"].presence&.strip || WebauthnOrigin.host(normalized_origin)

WebAuthn.configure do |config|
  # 3.4 以降は allowed_origins (複数形) が正。origin= は非推奨で、将来削除される
  config.allowed_origins = Array(normalized_origin)
  config.rp_name = "つみくら"
  config.rp_id = webauthn_rp_id
  # 生体認証のダイアログを出したまま放置される時間。ミリ秒
  config.credential_options_timeout = 120_000
end
