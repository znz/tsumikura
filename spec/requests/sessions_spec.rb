require "rails_helper"

RSpec.describe "ログイン", type: :request do
  let(:invalid_credentials_message) { "メールアドレスまたはパスワードが違います。" }

  # Rack 3 のヘッダは小文字、値は文字列にも配列にもなりうる
  def session_cookie_attributes
    header = response.headers["Set-Cookie"] || response.headers["set-cookie"]
    lines = header.is_a?(Array) ? header : header.to_s.split("\n")
    lines.find { |line| line.start_with?("session_id=") }.to_s.downcase
  end

  describe "認証の要求" do
    it "未ログインで / にアクセスするとログイン画面にリダイレクトされる" do
      get root_path

      expect(response).to redirect_to new_session_path
    end

    it "未ログインでもログイン画面は表示できる" do
      get new_session_path

      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /session" do
    it "正しいメールアドレスとパスワードでログインするとダッシュボードに遷移する" do
      user = create(:user)

      sign_in user

      expect(response).to redirect_to root_url
      follow_redirect!
      expect(response).to have_http_status(:ok)
    end

    # SessionsController#create はセッション固定攻撃の対策で reset_session するので、
    # 復帰先は reset_session より前に読み出さなければならない
    it "ログイン前にアクセスしようとした URL に戻る (reset_session で失わない)" do
      user = create(:user)
      get account_path

      sign_in user

      expect(response).to redirect_to account_url
    end

    it "GET 以外で認証を要求されたときは、その URL を復帰先にしない" do
      user = create(:user)
      patch account_password_path,
        params: { current_password: "family-password", password: "new-family-password", password_confirmation: "new-family-password" }
      expect(response).to redirect_to new_session_path

      sign_in user

      expect(response).to redirect_to root_url
    end

    it "セッション cookie には httponly と SameSite=Lax が付く" do
      sign_in create(:user)

      expect(session_cookie_attributes).to include "httponly"
      expect(session_cookie_attributes).to include "samesite=lax"
    end

    it "総当たりを防ぐため rate_limit が掛かっている" do
      keys = rate_limit_keys { sign_in create(:user) }

      expect(keys).to include(a_string_matching(/\Arate-limit:sessions/))
    end

    it "メールアドレスが配列で送られてきたら 400 で拒否する (500 にしない)" do
      post session_path, params: { email_address: [ "nobody@example.com" ], password: "family-password" }

      expect(response).to have_http_status(:bad_request)
    end

    it "パスワードが送られてこなければ 400 で拒否する (500 にしない)" do
      post session_path, params: { email_address: "nobody@example.com" }

      expect(response).to have_http_status(:bad_request)
    end

    it "誤ったパスワードではログインできない" do
      user = create(:user)

      sign_in user, password: "wrong-password"

      expect(response).to redirect_to new_session_path
      expect(flash[:alert]).to eq invalid_credentials_message
      get root_path
      expect(response).to redirect_to new_session_path
    end

    it "登録されていないメールアドレスではログインできない" do
      post session_path, params: { email_address: "nobody@example.com", password: "family-password" }

      expect(response).to redirect_to new_session_path
      expect(flash[:alert]).to eq invalid_credentials_message
    end

    # 最小長の引き上げ (8 -> 12) は「パスワードを設定・変更するとき」にしか効かない。
    # 引き上げ前からある短いパスワードのユーザーを締め出さないことを固定する
    it "最小長の引き上げ前に作られた短いパスワードでもログインできる" do
      legacy_password = "a" * 8
      user = build(:user, password: legacy_password)
      user.save!(validate: false)

      sign_in user, password: legacy_password

      expect(response).to redirect_to root_url
    end

    it "無効化されたユーザーは正しいパスワードでもログインできない" do
      user = create(:user, :deactivated)

      sign_in user

      expect(response).to redirect_to new_session_path
      get root_path
      expect(response).to redirect_to new_session_path
    end

    it "無効化されたユーザーのエラーメッセージはパスワード誤りと区別できない" do
      user = create(:user, :deactivated)

      sign_in user

      expect(flash[:alert]).to eq invalid_credentials_message
    end

    it "ログインに成功すると Session が 1 件作られ、ブラウザと IP が記録される" do
      user = create(:user)

      expect { sign_in user }.to change { user.sessions.count }.by(1)
      expect(user.sessions.last.ip_address).to be_present
    end
  end

  describe "DELETE /session" do
    it "ログアウトするとログイン画面に戻り、セッションが削除される" do
      user = create(:user)
      sign_in user

      expect { sign_out }.to change { user.sessions.count }.by(-1)
      expect(response).to redirect_to new_session_path
    end

    # terminate_session は reset_session するので、お知らせはそのあとに積む必要がある
    it "ログアウトするとお知らせが出る (reset_session で消えない)" do
      sign_in create(:user)

      sign_out

      expect(flash[:notice]).to be_present
    end

    it "ログアウト後は / にアクセスできない" do
      sign_in create(:user)
      sign_out

      get root_path

      expect(response).to redirect_to new_session_path
    end
  end

  # ログアウトした端末に通知が届き続けないよう、その端末の購読だけを消す
  # (docs/spec/04-notifications.md 5 節)。endpoint は logout_controller.js が hidden で送る
  describe "DELETE /session (この端末の通知の購読を消す)" do
    let(:user) { create(:user) }

    it "送られてきた endpoint の購読を消す" do
      subscription = create(:web_push_subscription, user: user)
      sign_in user

      expect { delete session_path, params: { push_endpoint: subscription.endpoint } }
        .to change { user.web_push_subscriptions.count }.by(-1)
      expect(response).to redirect_to new_session_path
    end

    it "同じユーザーの別の端末の購読は消さない" do
      subscription = create(:web_push_subscription, user: user)
      other_device = create(:web_push_subscription, user: user)
      sign_in user

      delete session_path, params: { push_endpoint: subscription.endpoint }

      expect(WebPushSubscription.exists?(other_device.id)).to be true
    end

    # endpoint は一意なので「他人の endpoint」を送ることでしか他人の購読は狙えない
    it "他人の購読の endpoint を送っても消えない" do
      others = create(:web_push_subscription, user: create(:user))
      sign_in user

      expect { delete session_path, params: { push_endpoint: others.endpoint } }
        .not_to change { WebPushSubscription.count }
      expect(response).to redirect_to new_session_path
    end

    it "存在しない endpoint を送っても普通にログアウトできる" do
      sign_in user

      delete session_path, params: { push_endpoint: "https://fcm.googleapis.com/wp/unknown" }

      expect(response).to redirect_to new_session_path
      expect(user.sessions.count).to eq 0
    end

    it "パラメータが無くてもログアウトできる (JS 無しの環境)" do
      subscription = create(:web_push_subscription, user: user)
      sign_in user

      expect { sign_out }.not_to change { WebPushSubscription.count }
      expect(response).to redirect_to new_session_path
      expect(WebPushSubscription.exists?(subscription.id)).to be true
    end

    it "String でないパラメータでも 500 にせずログアウトできる" do
      sign_in user

      delete session_path, params: { push_endpoint: [ "https://fcm.googleapis.com/wp/a" ] }

      expect(response).to redirect_to new_session_path
      expect(user.sessions.count).to eq 0
    end

    it "長すぎる endpoint でもログアウトできる" do
      sign_in user

      delete session_path,
        params: { push_endpoint: "https://fcm.googleapis.com/wp/#{"a" * WebPushSubscription::MAX_ENDPOINT_LENGTH}" }

      expect(response).to redirect_to new_session_path
      expect(user.sessions.count).to eq 0
    end

    it "push_endpoint はログに残さない" do
      filtered = ActiveSupport::ParameterFilter
        .new(Rails.application.config.filter_parameters)
        .filter("push_endpoint" => "https://fcm.googleapis.com/wp/secret")

      expect(filtered["push_endpoint"]).to eq "[FILTERED]"
    end
  end

  describe "メニューのログアウトボタン" do
    it "この端末の購読を消すための Stimulus controller を持つ" do
      sign_in create(:user)

      get menu_path

      form = response.parsed_body.at(%(form[action="#{session_path}"][data-controller="logout"]))
      expect(form).to be_present
      expect(form.at(%(input[type="hidden"][data-logout-target="endpoint"]))).to be_present
      expect(form["data-action"]).to include "submit->logout#submit"
    end
  end

  describe "無効化とセッションの失効" do
    it "ログイン後に無効化されると、既存のセッションでもアクセスできない" do
      user = create(:user)
      create(:user, :admin)
      sign_in user

      user.update!(deactivated_at: Time.current)

      get root_path
      expect(response).to redirect_to new_session_path
    end
  end
end
