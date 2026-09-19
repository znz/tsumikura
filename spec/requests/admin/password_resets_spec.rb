require "rails_helper"

RSpec.describe "管理者によるパスワード再設定", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:member) { create(:user) }

  def displayed_password
    response.parsed_body.at("#generated-password").text.strip
  end

  # Rack 3 のヘッダは小文字なので、どちらの綴りでも拾えるようにする
  def response_cache_control
    (response.headers["Cache-Control"] || response.headers["cache-control"]).to_s
  end

  it "一般ユーザーは他人のパスワードを再設定できない" do
    sign_in create(:user)

    post admin_user_password_reset_path(member)

    expect(response).to have_http_status(:forbidden)
    expect(member.reload.authenticate("password")).to be_truthy
  end

  describe "管理者の操作" do
    before { sign_in admin }

    it "確認画面を表示できる" do
      get new_admin_user_password_reset_path(member)

      expect(response).to have_http_status(:ok)
    end

    it "新しいパスワードが画面に 1 度だけ表示される" do
      post admin_user_password_reset_path(member)
      password = displayed_password

      expect(password).to be_present

      get admin_users_path
      expect(response.body).not_to include password
    end

    it "新しいパスワードは flash に載せない" do
      post admin_user_password_reset_path(member)

      expect(flash.to_hash.values.join).not_to include displayed_password
    end

    it "再設定すると元のパスワードでログインできなくなる" do
      post admin_user_password_reset_path(member)
      sign_out

      sign_in member

      expect(response).to redirect_to new_session_path
    end

    it "表示された新しいパスワードでログインできる" do
      post admin_user_password_reset_path(member)
      password = displayed_password
      sign_out

      post session_path, params: { email_address: member.email_address, password: password }

      expect(response).to redirect_to root_url
    end

    it "再設定すると対象ユーザーの既存セッションが失効する" do
      member.sessions.create!(ip_address: "127.0.0.1", user_agent: "rspec")

      expect { post admin_user_password_reset_path(member) }.to change { member.sessions.count }.to(0)
    end

    it "再設定しても他のユーザーのセッションは失効しない" do
      other = create(:user)
      other.sessions.create!(ip_address: "127.0.0.1", user_agent: "rspec")

      expect { post admin_user_password_reset_path(member) }.not_to change { other.sessions.count }
    end

    it "新しいパスワードの画面はブラウザにキャッシュさせない" do
      post admin_user_password_reset_path(member)

      expect(response_cache_control).to include "no-store"
    end

    it "新しいパスワードの画面は Turbo のスナップショットにも残さない (戻るで再表示されない)" do
      post admin_user_password_reset_path(member)

      expect(response.parsed_body.at("meta[name='turbo-cache-control']")["content"]).to eq "no-cache"
    end

    it "再読み込みすると別のパスワードが再発行されることを注意書きする" do
      post admin_user_password_reset_path(member)

      expect(response.body).to include "再読み込み"
    end

    # data-turbo=false を外すと Turbo がリダイレクトを要求し、
    # 「再設定されたのに新しいパスワードを誰も見ていない」状態になる
    it "発行ボタンは Turbo のフォーム処理を使わない" do
      get new_admin_user_password_reset_path(member)

      expect(response.parsed_body.at("form")["data-turbo"]).to eq "false"
    end
  end

  describe "自分自身への再設定" do
    before { sign_in admin }

    it "確認画面を開こうとするとアカウント設定に案内される" do
      get new_admin_user_password_reset_path(admin)

      expect(response).to redirect_to account_path
      expect(flash[:alert]).to be_present
    end

    it "再設定を実行してもパスワードは変わらず、自分のセッションも消えない" do
      expect {
        post admin_user_password_reset_path(admin)
      }.not_to change { admin.sessions.count }

      expect(admin.reload.authenticate("password")).to be_truthy
      expect(response).to redirect_to account_path
    end

    it "一覧には自分の行のパスワード再設定リンクを出さない (他人の行には出る)" do
      member

      get admin_users_path

      expect(response.body).to include new_admin_user_password_reset_path(member)
      expect(response.body).not_to include new_admin_user_password_reset_path(admin)
    end
  end
end
