require "rails_helper"

# パスキーの登録と削除 (docs/spec/05-auth.md 5 節)。
# 認証 (ログイン) は spec/requests/sessions/passkeys_spec.rb。
RSpec.describe "パスキーの登録", type: :request do
  let(:user) { create(:user, name: "たろう") }

  before { sign_in user }

  describe "POST /passkeys/options" do
    it "ログイン済みユーザーは登録オプションを取得できる" do
      post options_passkeys_path, params: { current_password: "password" }, as: :json

      expect(response).to have_http_status(:ok)
      options = response.parsed_body
      expect(options["challenge"]).to be_present
      expect(options["rp"]["name"]).to eq "つみくら"
      expect(options["user"]["name"]).to eq user.email_address
      expect(options["user"]["displayName"]).to eq "たろう"
    end

    it "discoverable credential (resident key) と生体認証 / PIN を要求する" do
      post options_passkeys_path, params: { current_password: "password" }, as: :json

      # residentKey: メール入力なしのログインに要る
      # userVerification: パスキー 1 つでログインできる以上、「持っているだけ」で入れてはいけない
      expect(response.parsed_body["authenticatorSelection"]).to include(
        "residentKey" => "required", "userVerification" => "required"
      )
    end

    it "初回に webauthn_id を生成し、2 回目は変えない" do
      expect { post options_passkeys_path, params: { current_password: "password" }, as: :json }
        .to change { user.reload.webauthn_id }.from(nil)

      expect { post options_passkeys_path, params: { current_password: "password" }, as: :json }
        .not_to change { user.reload.webauthn_id }
    end

    it "登録済みのパスキーを excludeCredentials に載せる (同じ端末で 2 つ作らせない)" do
      existing = create(:passkey, user: user)

      post options_passkeys_path, params: { current_password: "password" }, as: :json

      expect(response.parsed_body["excludeCredentials"].map { |c| c["id"] }).to eq [ existing.external_id ]
    end

    it "他人のパスキーは excludeCredentials に載せない" do
      create(:passkey)

      post options_passkeys_path, params: { current_password: "password" }, as: :json

      expect(response.parsed_body["excludeCredentials"]).to be_blank
    end

    it "現在のパスワードが違うと 401 で challenge を出さない" do
      post options_passkeys_path, params: { current_password: "ちがう" }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["challenge"]).to be_nil
    end

    it "パスワードが無くても 500 にしない" do
      post options_passkeys_path, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /passkeys" do
    it "FakeClient で作った credential を登録すると Passkey が作られる" do
      credential = nil
      expect { credential = register_passkey(nickname: "たろうのiPhone") }.to change(Passkey, :count).by 1

      expect(response).to have_http_status(:created)
      passkey = Passkey.sole
      expect(passkey).to have_attributes(user: user, nickname: "たろうのiPhone")
      expect(passkey.external_id).to eq credential["id"]
      expect(passkey.public_key).to be_present
      expect(passkey.last_used_at).to be_nil
    end

    it "名前が空なら User-Agent から既定の名前を付ける" do
      challenge = request_registration_challenge
      credential = fake_client.create(challenge: challenge, user_verified: true)

      post passkeys_path, params: { credential: credential.to_json, nickname: "  " },
        headers: { "User-Agent" => "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Version/18.0 Safari/605.1" },
        as: :json

      expect(Passkey.sole.nickname).to eq "iPhone / Safari"
    end

    it "名前は 50 文字に切り詰める" do
      register_passkey(nickname: "あ" * 80)

      expect(Passkey.sole.nickname.length).to eq 50
    end

    # --- ここから拒否 ---

    it "challenge が一致しない credential は登録を拒否される" do
      request_registration_challenge
      credential = fake_client.create(challenge: unrelated_challenge, user_verified: true)

      expect { post passkeys_path, params: { credential: credential.to_json }, as: :json }
        .not_to change(Passkey, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "パスワードの再確認なし (challenge 未発行) では登録できない" do
      credential = fake_client.create(challenge: unrelated_challenge, user_verified: true)

      expect { post passkeys_path, params: { credential: credential.to_json }, as: :json }
        .not_to change(Passkey, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "パスワードを間違えたあとでは登録できない" do
      post options_passkeys_path, params: { current_password: "ちがう" }, as: :json
      credential = fake_client.create(challenge: unrelated_challenge, user_verified: true)

      expect { post passkeys_path, params: { credential: credential.to_json }, as: :json }
        .not_to change(Passkey, :count)
    end

    it "challenge は 1 回限り (同じ credential を送り直せない)" do
      challenge = request_registration_challenge
      credential = fake_client.create(challenge: challenge, user_verified: true)
      post passkeys_path, params: { credential: credential.to_json }, as: :json
      expect(response).to have_http_status(:created)

      expect { post passkeys_path, params: { credential: credential.to_json }, as: :json }
        .not_to change(Passkey, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "別の origin で作られた credential は拒否される (フィッシング対策)" do
      challenge = request_registration_challenge
      # rp_id は本物に合わせ、clientDataJSON の origin だけが別になるようにする
      credential = evil_client.create(challenge: challenge, rp_id: configured_rp_id, user_verified: true)

      expect { post passkeys_path, params: { credential: credential.to_json }, as: :json }
        .not_to change(Passkey, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "壊れた credential で 500 にしない" do
      # id が String でない形も含める (gem は Hash / 配列 / 数値の id をそのまま通す)
      broken_credentials = [
        nil, "", "{", '["a"]', '{"type":"public-key"}', [ "a" ],
        '{"id":{"a":"b"}}', '{"id":["x"]}', '{"id":1}', '{"id":null}'
      ]

      broken_credentials.each do |broken|
        request_registration_challenge

        expect { post passkeys_path, params: { credential: broken }, as: :json }
          .not_to change(Passkey, :count)

        expect(response).to have_http_status(:unprocessable_content), "credential=#{broken.inspect}"
      end
    end

    # パスキー 1 つでログインできる以上、「持っているだけ」で登録させてはいけない
    # (PIN を設定していない USB セキュリティキーを拾った人が挿すだけで足せてしまう)
    it "生体認証 / PIN を通していない credential は登録を拒否される" do
      challenge = request_registration_challenge
      credential = fake_client.create(challenge: challenge, user_verified: false)

      expect { post passkeys_path, params: { credential: credential.to_json }, as: :json }
        .not_to change(Passkey, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    # セッションキーを登録用と認証用で分けていないと通ってしまう。
    # 未ログインで叩ける /sessions/passkey/options の challenge で登録できたら、
    # パスワードの再確認を迂回できる
    it "認証用の options で得た challenge では登録できない" do
      challenge = request_authentication_challenge
      credential = fake_client.create(challenge: challenge, user_verified: true)

      expect { post passkeys_path, params: { credential: credential.to_json }, as: :json }
        .not_to change(Passkey, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    # challenge を session.delete ではなく session[] で読むと落ちない
    it "失敗した試行でも challenge は捨てられる" do
      challenge = request_registration_challenge
      # 1 回目は壊れた credential で失敗させる
      post passkeys_path, params: { credential: "{}" }, as: :json
      expect(response).to have_http_status(:unprocessable_content)

      # 同じ challenge の**正しい** credential を送っても、もう使えない
      credential = fake_client.create(challenge: challenge, user_verified: true)

      expect { post passkeys_path, params: { credential: credential.to_json }, as: :json }
        .not_to change(Passkey, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    # 生体認証をキャンセルすると challenge がセッションに残る。CookieStore なので
    # session.delete では無効化できず、その Cookie を盗まれるとパスワードなしで登録できてしまう
    it "期限 (5 分) を過ぎた challenge では登録できない" do
      challenge = request_registration_challenge
      credential = fake_client.create(challenge: challenge, user_verified: true)

      travel PasskeysController::CHALLENGE_TTL + 1.minute do
        expect { post passkeys_path, params: { credential: credential.to_json }, as: :json }
          .not_to change(Passkey, :count)

        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    it "期限内であれば登録できる (期限の判定が厳しすぎない)" do
      challenge = request_registration_challenge
      credential = fake_client.create(challenge: challenge, user_verified: true)

      travel PasskeysController::CHALLENGE_TTL - 1.minute do
        expect { post passkeys_path, params: { credential: credential.to_json }, as: :json }
          .to change(Passkey, :count).by 1
      end
    end

    it "同じ端末から 2 つ登録できる (FakeClient は create のたびに別の credential を作る)" do
      register_passkey(nickname: "1 つ目")
      register_passkey(nickname: "2 つ目")

      expect(user.passkeys.pluck(:nickname)).to contain_exactly "1 つ目", "2 つ目"
      expect(user.passkeys.pluck(:external_id).uniq.size).to eq 2
    end
  end

  describe "DELETE /passkeys/:id" do
    it "自分のパスキーを削除できる" do
      passkey = create(:passkey, user: user)

      expect { delete passkey_path(passkey) }.to change(Passkey, :count).by(-1)

      expect(response).to redirect_to account_path
    end

    it "他人のパスキーは削除できない" do
      other = create(:passkey)

      expect { delete passkey_path(other) }.not_to change(Passkey, :count)

      expect(response).to redirect_to account_path
    end

    it "すでに削除済みのパスキーへの削除でも 404 を見せない (古い画面からの操作)" do
      passkey = create(:passkey, user: user)
      passkey.destroy!

      delete passkey_path(passkey)

      expect(response).to redirect_to account_path
    end
  end

  describe "rate_limit" do
    it "登録オプションの取得に rate_limit が掛かっている" do
      keys = rate_limit_keys { post options_passkeys_path, params: { current_password: "password" }, as: :json }

      expect(keys).to include(a_string_matching(%r{\Arate-limit:passkeys:options}))
    end

    it "登録に rate_limit が掛かっている" do
      keys = rate_limit_keys { post passkeys_path, params: { credential: "{}" }, as: :json }

      expect(keys).to include(a_string_matching(%r{\Arate-limit:passkeys:create}))
    end
  end

  describe "アカウント設定の表示" do
    it "登録済みのパスキーが名前・登録日・最終利用とともに並ぶ" do
      create(:passkey, user: user, nickname: "たろうのiPhone", last_used_at: Time.current)

      get account_path

      list = Nokogiri::HTML(response.body).at("ul[aria-label='登録済みのパスキー']")
      expect(list.text).to include "たろうのiPhone"
      expect(list.text).to include "最終利用"
    end

    it "他人のパスキーは出さない" do
      create(:passkey, nickname: "はなこのAndroid")

      get account_path

      list = Nokogiri::HTML(response.body).at("ul[aria-label='登録済みのパスキー']")
      expect(list).to be_nil
    end

    it "登録フォームと Stimulus の data 属性が出ている (実ブラウザでの登録に要る)" do
      get account_path

      section = Nokogiri::HTML(response.body).at("[data-controller='passkey']")
      expect(section["data-passkey-url-value"]).to eq passkeys_path
      expect(section["data-passkey-options-url-value"]).to eq options_passkeys_path
      expect(section.at("[data-passkey-target='password']")).to be_present
      expect(section.at("[data-passkey-target='nickname']")).to be_present
      expect(section.at("form[data-action='submit->passkey#register']")).to be_present
    end
  end

  describe "パスワードとの関係" do
    it "パスキーが 0 件でもパスワードでログインできる (パスキーは追加の手段)" do
      sign_out

      sign_in user

      expect(response).to redirect_to root_url
    end

    it "パスキーを登録してもパスワードでログインできる" do
      register_passkey
      sign_out

      sign_in user

      expect(response).to redirect_to root_url
    end
  end
end
