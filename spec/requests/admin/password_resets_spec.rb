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
    expect(member.reload.authenticate("family-password")).to be_truthy
  end

  describe "管理者の操作" do
    before { sign_in admin }

    it "確認画面を表示できる" do
      get new_admin_user_password_reset_path(member)

      expect(response).to have_http_status(:ok)
    end

    # 再設定は「乗っ取られたかもしれない」ときの操作でもある。パスキーを残すと
    # 攻撃者が登録したパスキーで入り続けられる (docs/spec/05-auth.md 5 節)
    it "確認画面に削除されるパスキーの件数を出す" do
      create_list(:passkey, 2, user: member)

      get new_admin_user_password_reset_path(member)

      expect(response.parsed_body.at("[data-passkey-count]").text).to include "2 件"
    end

    it "再設定すると対象ユーザーのパスキーをすべて削除する" do
      create_list(:passkey, 2, user: member)
      other = create(:passkey)

      expect { post admin_user_password_reset_path(member) }.to change(Passkey, :count).by(-2)

      expect(member.reload.passkeys).to be_empty
      expect(Passkey.exists?(other.id)).to be true
    end

    it "削除したパスキーの件数を画面に出す" do
      create_list(:passkey, 2, user: member)

      post admin_user_password_reset_path(member)

      expect(response.parsed_body.at("[data-removed-passkeys]").text).to include "2 件"
    end

    it "パスキーを持たないユーザーでも再設定できる" do
      expect { post admin_user_password_reset_path(member) }.not_to raise_error

      expect(response.parsed_body.at("[data-removed-passkeys]")).to be_nil
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

      expect(admin.reload.authenticate("family-password")).to be_truthy
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
