require "webauthn/fake_client"

# パスキー (docs/spec/05-auth.md 5 節) の request spec 用ヘルパー。
#
# WebAuthn::FakeClient は **Hash** を返す (webauthn 3.4.3 で確認)。コントローラは
# credential を JSON 文字列で受けるので、送るときに to_json する。
# FakeClient の origin は config/initializers/webauthn.rb の allowed_origins
# (test 環境では request spec の既定ホスト http://www.example.com) と合わせる。
module WebauthnHelper
  DEFAULT_ORIGIN = "http://www.example.com".freeze

  # この example の「この端末」。create のたびに新しい credential を作り、
  # 作った credential は認証器 (fake_authenticator) が rp_id ごとに覚えている
  def fake_client(origin = DEFAULT_ORIGIN)
    @fake_client ||= WebAuthn::FakeClient.new(origin, authenticator: fake_authenticator)
  end

  def fake_authenticator
    @fake_authenticator ||= WebAuthn::FakeAuthenticator.new
  end

  # 別の端末 (別の認証器)。登録していない credential を作るのに使う
  def new_fake_client(origin = DEFAULT_ORIGIN)
    WebAuthn::FakeClient.new(origin)
  end

  # **同じ認証器を別 origin のサイトから使う** (フィッシングの再現)。
  # rp_id を明示すると、認証器が持っている本物の credential をそのまま使える。
  # 違うのは clientDataJSON の origin だけになるので、origin の検証だけを試せる
  def evil_client(origin = "http://evil.example.com")
    @evil_client ||= WebAuthn::FakeClient.new(origin, authenticator: fake_authenticator)
  end

  def configured_rp_id
    WebAuthn.configuration.rp_id
  end

  # ---- 登録 ----

  # options を取り、その challenge で credential を作って登録まで済ませる。
  # ログインは呼び出し側で済ませておくこと (現在のパスワードの再確認が要るため)
  def register_passkey(password: AuthenticationHelper::DEFAULT_PASSWORD, nickname: nil, client: fake_client)
    challenge = request_registration_challenge(password: password)
    credential = client.create(challenge: challenge, user_verified: true)

    post passkeys_path, params: { credential: credential.to_json, nickname: nickname }.compact, as: :json

    credential
  end

  # challenge だけを取り出す (登録の前半)
  def request_registration_challenge(password: AuthenticationHelper::DEFAULT_PASSWORD)
    post options_passkeys_path, params: { current_password: password }, as: :json

    response.parsed_body["challenge"]
  end

  # ---- 認証 ----

  # 未ログインの状態から、登録済みのパスキーでログインする
  def sign_in_with_passkey(client: fake_client, sign_count: nil)
    challenge = request_authentication_challenge
    credential = client.get(challenge: challenge, user_verified: true, sign_count: sign_count)

    post sessions_passkey_path, params: { credential: credential.to_json }, as: :json

    credential
  end

  def request_authentication_challenge
    post options_sessions_passkey_path, as: :json

    response.parsed_body["challenge"]
  end

  # WebAuthn.generate_user_id が返す base64url の文字列を、認証器が持つ生のバイト列に戻す。
  # FakeClient#get(user_handle:) には**生のバイト列**を渡す (credential.user_handle で
  # base64url に戻ってくる。実測で確認した)
  def raw_user_handle(user)
    WebAuthn.configuration.relying_party.encoder.decode(user.webauthn_id)
  end

  # 使い回されない (= 必ず一致しない) challenge。形だけ本物に合わせる
  def unrelated_challenge
    WebAuthn.configuration.relying_party.encoder.encode(SecureRandom.random_bytes(32))
  end
end

RSpec.configure do |config|
  config.include WebauthnHelper, type: :request
end
