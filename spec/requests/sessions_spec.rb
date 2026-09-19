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
        params: { current_password: "password", password: "newpassword", password_confirmation: "newpassword" }
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
      post session_path, params: { email_address: [ "nobody@example.com" ], password: "password" }

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
      post session_path, params: { email_address: "nobody@example.com", password: "password" }

      expect(response).to redirect_to new_session_path
      expect(flash[:alert]).to eq invalid_credentials_message
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
