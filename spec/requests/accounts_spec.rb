require "rails_helper"

RSpec.describe "アカウント設定", type: :request do
  let(:user) { create(:user, name: "おかあさん") }

  before { sign_in user }

  describe "GET /account" do
    it "自分の表示名とメールアドレスが表示される" do
      get account_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include "おかあさん"
      expect(response.body).to include user.email_address
    end

    it "ログイン中のセッションが一覧される" do
      user.sessions.create!(ip_address: "192.0.2.10", user_agent: "べつのブラウザ")

      get account_path

      expect(response.body).to include "192.0.2.10"
      expect(response.body).to include "べつのブラウザ"
    end

    it "現在のセッションにだけ印が付く" do
      user.sessions.create!(ip_address: "192.0.2.10", user_agent: "べつのブラウザ")

      get account_path

      badges = response.parsed_body.css("[data-current-session]")
      expect(badges.size).to eq 1
      expect(badges.text).to include "このデバイス"
    end

    it "他人のセッションは一覧されない" do
      other = create(:user)
      other.sessions.create!(ip_address: "198.51.100.1", user_agent: "よそのブラウザ")

      get account_path

      expect(response.body).not_to include "198.51.100.1"
    end
  end

  describe "PATCH /account" do
    it "表示名を変更できる" do
      patch account_path, params: { user: { name: "おとうさん", email_address: user.email_address } }

      expect(user.reload.name).to eq "おとうさん"
      expect(response).to redirect_to account_path
    end

    it "メールアドレスを変更できる" do
      patch account_path, params: { user: { name: user.name, email_address: "new@example.com" } }

      expect(user.reload.email_address).to eq "new@example.com"
    end

    it "不正なメールアドレスは保存されない" do
      patch account_path, params: { user: { name: user.name, email_address: "こわれている" } }

      expect(user.reload.email_address).not_to eq "こわれている"
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "自分で役割を管理者に変更することはできない" do
      patch account_path, params: { user: { name: user.name, email_address: user.email_address, role: "admin" } }

      expect(user.reload).to be_member
    end

    it "自分で自分を無効化することはできない" do
      patch account_path,
        params: { user: { name: user.name, email_address: user.email_address, deactivated_at: Time.current } }

      expect(user.reload).not_to be_deactivated
    end
  end

  describe "PATCH /account/password" do
    it "現在のパスワードが正しければ変更できる" do
      patch account_password_path, params: {
        current_password: "password", password: "newpassword", password_confirmation: "newpassword"
      }

      expect(user.reload.authenticate("newpassword")).to be_truthy
      expect(response).to redirect_to account_path
    end

    it "変更後は新しいパスワードでログインできる" do
      patch account_password_path, params: {
        current_password: "password", password: "newpassword", password_confirmation: "newpassword"
      }
      sign_out

      sign_in user, password: "newpassword"

      expect(response).to redirect_to root_url
    end

    it "現在のパスワードが違えば変更できない" do
      patch account_password_path, params: {
        current_password: "wrong-password", password: "newpassword", password_confirmation: "newpassword"
      }

      expect(user.reload.authenticate("newpassword")).to be false
      expect(flash[:alert]).to be_present
    end

    it "現在のパスワードが空なら変更できない" do
      patch account_password_path, params: {
        current_password: "", password: "newpassword", password_confirmation: "newpassword"
      }

      expect(user.reload.authenticate("newpassword")).to be false
    end

    it "確認用のパスワードが一致しなければ変更できない" do
      patch account_password_path, params: {
        current_password: "password", password: "newpassword", password_confirmation: "mismatched"
      }

      expect(user.reload.authenticate("newpassword")).to be false
      expect(flash[:alert]).to be_present
    end

    it "短すぎるパスワードには変更できない" do
      short = "a" * (User::MINIMUM_PASSWORD_LENGTH - 1)

      patch account_password_path, params: {
        current_password: "password", password: short, password_confirmation: short
      }

      expect(user.reload.authenticate(short)).to be false
      expect(flash[:alert]).to be_present
    end

    # has_secure_password は空文字の代入を黙って無視するので、
    # 弾かないと「何も変わっていないのに変更しました」になる
    it "新しいパスワードが空なら変更できない" do
      patch account_password_path, params: {
        current_password: "password", password: "", password_confirmation: ""
      }

      expect(user.reload.authenticate("password")).to be_truthy
      expect(flash[:alert]).to be_present
      expect(flash[:notice]).to be_blank
    end

    it "新しいパスワードが送られてこなければ変更できない" do
      patch account_password_path, params: { current_password: "password" }

      expect(user.reload.authenticate("password")).to be_truthy
      expect(flash[:alert]).to be_present
      expect(flash[:notice]).to be_blank
    end

    it "変更するとこのデバイス以外のセッションが失効し、現在のセッションは残る" do
      current_session = user.sessions.last
      user.sessions.create!(ip_address: "192.0.2.10", user_agent: "べつのブラウザ")
      user.sessions.create!(ip_address: "192.0.2.11", user_agent: "もうひとつのブラウザ")

      patch account_password_path, params: {
        current_password: "password", password: "newpassword", password_confirmation: "newpassword"
      }

      expect(user.sessions.reload).to contain_exactly(current_session)
      get root_path
      expect(response).to have_http_status(:ok)
    end

    it "変更に失敗したら他のセッションは失効しない" do
      user.sessions.create!(ip_address: "192.0.2.10", user_agent: "べつのブラウザ")

      expect {
        patch account_password_path, params: {
          current_password: "wrong-password", password: "newpassword", password_confirmation: "newpassword"
        }
      }.not_to change { user.sessions.count }
    end

    it "他人のセッションは失効しない" do
      other = create(:user)
      other.sessions.create!(ip_address: "198.51.100.1", user_agent: "よそのブラウザ")

      expect {
        patch account_password_path, params: {
          current_password: "password", password: "newpassword", password_confirmation: "newpassword"
        }
      }.not_to change { other.sessions.count }
    end

    it "総当たりを防ぐため rate_limit が掛かっている" do
      keys = rate_limit_keys do
        patch account_password_path, params: {
          current_password: "password", password: "newpassword", password_confirmation: "newpassword"
        }
      end

      expect(keys).to include(a_string_matching(%r{\Arate-limit:account/passwords}))
    end
  end

  describe "DELETE /account/sessions/:id" do
    it "他のデバイスのセッションを失効できる" do
      other_session = user.sessions.create!(ip_address: "192.0.2.10", user_agent: "べつのブラウザ")

      expect { delete account_session_path(other_session) }.to change { user.sessions.count }.by(-1)
      expect(response).to redirect_to account_path
    end

    it "現在のセッションを失効するとログアウトされる" do
      delete account_session_path(user.sessions.last)

      expect(response).to redirect_to new_session_path
      get root_path
      expect(response).to redirect_to new_session_path
    end

    it "他人のセッションは失効できない" do
      other = create(:user)
      other_session = other.sessions.create!(ip_address: "198.51.100.1", user_agent: "よそのブラウザ")

      delete account_session_path(other_session)

      expect(response).to have_http_status(:not_found)
      expect(other.sessions.count).to eq 1
    end
  end

  describe "DELETE /account/sessions/others" do
    it "このデバイス以外のセッションをすべて失効できる" do
      current_session = user.sessions.last
      user.sessions.create!(ip_address: "192.0.2.10", user_agent: "べつのブラウザ")
      user.sessions.create!(ip_address: "192.0.2.11", user_agent: "もうひとつのブラウザ")

      delete others_account_sessions_path

      expect(user.sessions.reload).to contain_exactly(current_session)
    end

    it "失効させたあともログインしたまま操作できる" do
      user.sessions.create!(ip_address: "192.0.2.10", user_agent: "べつのブラウザ")

      delete others_account_sessions_path

      get root_path
      expect(response).to have_http_status(:ok)
    end

    it "他人のセッションは失効しない" do
      other = create(:user)
      other.sessions.create!(ip_address: "198.51.100.1", user_agent: "よそのブラウザ")

      expect { delete others_account_sessions_path }.not_to change { other.sessions.count }
    end
  end
end
