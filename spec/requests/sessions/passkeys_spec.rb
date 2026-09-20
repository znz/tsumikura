require "rails_helper"

# パスキーでのログイン (docs/spec/05-auth.md 5 節)。
# 登録は spec/requests/passkeys_spec.rb。
RSpec.describe "パスキーでのログイン", type: :request do
  let(:user) { create(:user, name: "たろう") }

  # 登録を済ませてからログアウトする。ここから先は未ログインの状態
  def register_and_sign_out
    sign_in user
    register_passkey(nickname: "たろうのiPhone")
    expect(response).to have_http_status(:created)
    sign_out
  end

  # Rack 3 のヘッダは小文字、値は文字列にも配列にもなりうる (spec/requests/sessions_spec.rb と同じ)
  def session_cookie_line
    header = response.headers["Set-Cookie"] || response.headers["set-cookie"]
    lines = header.is_a?(Array) ? header : header.to_s.split("\n")
    lines.find { |line| line.start_with?("session_id=") }.to_s
  end

  describe "POST /sessions/passkey/options" do
    it "未ログインでも認証オプションを取得できる" do
      post options_sessions_passkey_path, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["challenge"]).to be_present
    end

    it "allowCredentials を渡さない (discoverable credential でメール入力なしにする)" do
      post options_sessions_passkey_path, as: :json

      expect(response.parsed_body["allowCredentials"]).to be_empty
    end

    it "生体認証 / PIN (user verification) を必須で要求する" do
      post options_sessions_passkey_path, as: :json

      expect(response.parsed_body["userVerification"]).to eq "required"
    end

    it "登録されているパスキーの数を漏らさない (誰も登録していなくても同じ応答)" do
      post options_sessions_passkey_path, as: :json
      without_passkey = response.parsed_body.keys.sort

      create(:passkey)
      post options_sessions_passkey_path, as: :json

      expect(response.parsed_body.keys.sort).to eq without_passkey
    end
  end

  describe "POST /sessions/passkey" do
    it "登録済みのパスキーで usernameless ログインできる" do
      register_and_sign_out

      expect { sign_in_with_passkey }.to change { user.sessions.count }.by 1

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["redirect_url"]).to eq root_url
    end

    it "ログインすると session_id の cookie が出る" do
      register_and_sign_out

      sign_in_with_passkey

      expect(session_cookie_line).to be_present
      expect(session_cookie_line.downcase).to include "httponly"
      expect(session_cookie_line.downcase).to include "samesite=lax"
    end

    it "ログインすると保護されたページを開ける" do
      register_and_sign_out

      sign_in_with_passkey
      get account_path

      expect(response).to have_http_status(:ok)
    end

    it "ログイン前にアクセスしようとした URL に戻る (reset_session で失わない)" do
      register_and_sign_out
      get account_path
      expect(response).to redirect_to new_session_path

      sign_in_with_passkey

      expect(response.parsed_body["redirect_url"]).to eq account_url
    end

    it "ログイン成功で Rails セッションがリセットされる (セッション固定攻撃の対策)" do
      register_and_sign_out
      # options で challenge を入れた時点の Rails セッション (cookie) を覚えておく
      challenge = request_authentication_challenge
      before_cookie = cookies[Rails.application.config.session_options[:key]]
      expect(before_cookie).to be_present
      credential = fake_client.get(challenge: challenge, user_verified: true)

      post sessions_passkey_path, params: { credential: credential.to_json }, as: :json

      expect(response).to have_http_status(:ok)
      expect(cookies[Rails.application.config.session_options[:key]]).not_to eq before_cookie
    end

    it "ログイン成功で sign_count と last_used_at が更新される" do
      register_and_sign_out
      passkey = Passkey.sole
      expect(passkey.sign_count).to eq 0
      expect(passkey.last_used_at).to be_nil

      sign_in_with_passkey

      passkey.reload
      expect(passkey.sign_count).to be > 0
      expect(passkey.last_used_at).to be_present
    end
  end

  describe "拒否" do
    # 失敗はすべて同じ文言・同じステータス (credential の有無・無効化を区別しない)
    def expect_uniform_rejection
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]).to eq Sessions::PasskeysController::FAILED_MESSAGE
    end

    it "存在しない external_id でのログインは拒否される" do
      # 登録していない認証器で ceremony だけ行う
      challenge = request_authentication_challenge
      unregistered = new_fake_client
      unregistered.create(challenge: challenge)
      credential = unregistered.get(challenge: challenge, user_verified: true)

      post sessions_passkey_path, params: { credential: credential.to_json }, as: :json

      expect_uniform_rejection
      expect(Session.count).to eq 0
    end

    it "無効化されたユーザーのパスキーではログインできない" do
      register_and_sign_out
      user.update!(deactivated_at: Time.current)

      sign_in_with_passkey

      expect_uniform_rejection
      expect(user.sessions.count).to eq 0
    end

    it "無効化の拒否は、存在しない credential の拒否と区別できない" do
      challenge = request_authentication_challenge
      unregistered = new_fake_client
      unregistered.create(challenge: challenge)
      post sessions_passkey_path,
        params: { credential: unregistered.get(challenge: challenge, user_verified: true).to_json }, as: :json
      missing = [ response.status, response.parsed_body ]

      register_and_sign_out
      user.update!(deactivated_at: Time.current)
      sign_in_with_passkey

      expect([ response.status, response.parsed_body ]).to eq missing
    end

    it "challenge が未発行なら拒否される (options を通さずには入れない)" do
      register_and_sign_out
      # challenge を取らずに ceremony だけ行う
      credential = fake_client.get(challenge: unrelated_challenge, user_verified: true)

      post sessions_passkey_path, params: { credential: credential.to_json }, as: :json

      expect_uniform_rejection
      expect(Session.count).to eq 0
    end

    it "challenge が一致しない credential は拒否される" do
      register_and_sign_out
      request_authentication_challenge
      credential = fake_client.get(challenge: unrelated_challenge, user_verified: true)

      post sessions_passkey_path, params: { credential: credential.to_json }, as: :json

      expect_uniform_rejection
    end

    it "challenge は 1 回限り (同じ credential を送り直せない)" do
      register_and_sign_out
      credential = sign_in_with_passkey
      expect(response).to have_http_status(:ok)
      sign_out

      post sessions_passkey_path, params: { credential: credential.to_json }, as: :json

      expect_uniform_rejection
    end

    it "別の origin から使われた credential は拒否される (フィッシング対策)" do
      register_and_sign_out
      challenge = request_authentication_challenge
      # 登録済みの本物の credential を、別 origin のページから使ったことにする
      credential = evil_client.get(challenge: challenge, rp_id: configured_rp_id, user_verified: true)
      expect(credential["id"]).to eq Passkey.sole.external_id

      post sessions_passkey_path, params: { credential: credential.to_json }, as: :json

      expect_uniform_rejection
    end

    it "sign_count が巻き戻った credential は拒否される (クローン検知)" do
      register_and_sign_out
      sign_in_with_passkey(sign_count: 50)
      expect(response).to have_http_status(:ok)
      expect(Passkey.sole.sign_count).to eq 50
      sign_out

      sign_in_with_passkey(sign_count: 10)

      expect_uniform_rejection
      expect(Passkey.sole.sign_count).to eq 50
    end

    it "パスキーを削除すると、それでログインできなくなる" do
      register_and_sign_out
      Passkey.sole.destroy!

      sign_in_with_passkey

      expect_uniform_rejection
      expect(Session.count).to eq 0
    end

    it "壊れた credential で 500 にしない" do
      register_and_sign_out

      # id が String でない形も含める (gem は Hash / 配列 / 数値の id をそのまま通すので、
      # 検証より前の Passkey.find_by(external_id:) に配列が渡って IN 検索になる)
      broken_credentials = [
        nil, "", "{", '["a"]', '{"type":"public-key"}', [ "a" ],
        '{"id":{"a":"b"}}', '{"id":["x"]}', '{"id":1}', '{"id":null}'
      ]

      broken_credentials.each do |broken|
        request_authentication_challenge

        post sessions_passkey_path, params: { credential: broken }, as: :json

        expect_uniform_rejection
      end

      expect(Session.count).to eq 0
    end

    it "パラメータが無くても 500 にしない" do
      post sessions_passkey_path, as: :json

      expect_uniform_rejection
    end

    # 認証器が user handle を返したら、登録時のものと一致すること
    # (別のユーザーの credential ID を混ぜられないように)
    it "登録時と違う user handle の assertion は拒否される" do
      register_and_sign_out
      challenge = request_authentication_challenge
      credential = fake_client.get(challenge: challenge, user_verified: true,
        user_handle: SecureRandom.random_bytes(64))

      post sessions_passkey_path, params: { credential: credential.to_json }, as: :json

      expect_uniform_rejection
      expect(Session.count).to eq 0
    end

    it "登録時と同じ user handle の assertion は受け付ける (照合が厳しすぎない)" do
      register_and_sign_out
      challenge = request_authentication_challenge
      credential = fake_client.get(challenge: challenge, user_verified: true,
        user_handle: raw_user_handle(user.reload))

      post sessions_passkey_path, params: { credential: credential.to_json }, as: :json

      expect(response).to have_http_status(:ok)
    end

    # パスキー 1 つでログインできる以上、「持っているだけ」で入れてはいけない
    # (PIN を設定していない USB セキュリティキーを拾った人が挿してタッチするだけで入れてしまう)
    it "生体認証 / PIN を通していない assertion は拒否される" do
      register_and_sign_out
      challenge = request_authentication_challenge
      credential = fake_client.get(challenge: challenge, user_verified: false)

      post sessions_passkey_path, params: { credential: credential.to_json }, as: :json

      expect_uniform_rejection
      expect(Session.count).to eq 0
    end

    # challenge を session.delete ではなく session[] で読むと落ちない
    it "失敗した試行でも challenge は捨てられる" do
      register_and_sign_out
      challenge = request_authentication_challenge
      # 1 回目は壊れた credential で失敗させる
      post sessions_passkey_path, params: { credential: "{}" }, as: :json
      expect_uniform_rejection

      # 同じ challenge の**正しい** assertion を送っても、もう使えない
      credential = fake_client.get(challenge: challenge, user_verified: true)
      post sessions_passkey_path, params: { credential: credential.to_json }, as: :json

      expect_uniform_rejection
      expect(Session.count).to eq 0
    end

    it "期限 (15 分) を過ぎた challenge では入れない" do
      register_and_sign_out
      challenge = request_authentication_challenge
      credential = fake_client.get(challenge: challenge, user_verified: true)

      travel Sessions::PasskeysController::CHALLENGE_TTL + 1.minute do
        post sessions_passkey_path, params: { credential: credential.to_json }, as: :json

        expect_uniform_rejection
        expect(Session.count).to eq 0
      end
    end

    it "期限内であれば入れる (期限の判定が厳しすぎない)" do
      register_and_sign_out
      challenge = request_authentication_challenge
      credential = fake_client.get(challenge: challenge, user_verified: true)

      travel Sessions::PasskeysController::CHALLENGE_TTL - 1.minute do
        post sessions_passkey_path, params: { credential: credential.to_json }, as: :json

        expect(response).to have_http_status(:ok)
      end
    end

    # **セッションは CookieStore なので session.delete だけでは 1 回限りにならない。**
    # 古い Cookie はサーバから見ると有効なまま。sign_count を常に 0 で返す同期型の
    # パスキー (iCloud / Google) では、カウンタ検証にも引っかからないので何度でも入れてしまう。
    # サーバ側の消費記録 (Rails.cache) だけがこれを止める
    it "同じ Cookie と assertion の組を送り直しても 2 回目は拒否される", :memory_cache do
      register_and_sign_out
      challenge = request_authentication_challenge
      stolen_cookie = cookies[Rails.application.config.session_options[:key]]
      # 同期型のパスキーを模して sign_count を 0 のままにする
      credential = fake_client.get(challenge: challenge, user_verified: true, sign_count: 0)

      post sessions_passkey_path, params: { credential: credential.to_json }, as: :json
      expect(response).to have_http_status(:ok)
      sign_out

      # 盗まれた古い Cookie を差し戻す (この Cookie にはまだ challenge が入っている)
      cookies[Rails.application.config.session_options[:key]] = stolen_cookie
      post sessions_passkey_path, params: { credential: credential.to_json }, as: :json

      expect_uniform_rejection
      expect(Session.count).to eq 0
    end
  end

  describe "rate_limit" do
    it "認証オプションの取得に rate_limit が掛かっている" do
      keys = rate_limit_keys { post options_sessions_passkey_path, as: :json }

      expect(keys).to include(a_string_matching(%r{\Arate-limit:sessions/passkeys:options}))
    end

    it "ログインの試行に rate_limit が掛かっている" do
      keys = rate_limit_keys { post sessions_passkey_path, params: { credential: "{}" }, as: :json }

      expect(keys).to include(a_string_matching(%r{\Arate-limit:sessions/passkeys:create}))
    end
  end

  describe "ログイン画面" do
    it "「パスキーでログイン」のボタンと Stimulus の data 属性が出ている" do
      get new_session_path

      section = Nokogiri::HTML(response.body).at("[data-controller='passkey-login']")
      expect(section["data-passkey-login-url-value"]).to eq sessions_passkey_path
      expect(section["data-passkey-login-options-url-value"]).to eq options_sessions_passkey_path
      expect(section.at("[data-action='passkey-login#signIn']").text).to include "パスキーでログイン"
    end

    it "メール欄に conditional UI 用の autocomplete が付く" do
      get new_session_path

      field = Nokogiri::HTML(response.body).at("input[name='email_address']")
      expect(field["autocomplete"]).to eq "username webauthn"
    end

    it "パスワードのフォームはそのまま残る (パスキーは追加の手段)" do
      get new_session_path

      expect(response.body).to include "パスワードを忘れたら管理者に再設定してもらってください。"
    end
  end
end
