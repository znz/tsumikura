require "rails_helper"

RSpec.describe "ユーザー管理", type: :request do
  # 作成・再設定の画面に 1 度だけ表示される生成パスワード
  def displayed_password
    response.parsed_body.at("#generated-password").text.strip
  end

  # Rack 3 のヘッダは小文字なので、どちらの綴りでも拾えるようにする
  def response_cache_control
    (response.headers["Cache-Control"] || response.headers["cache-control"]).to_s
  end

  describe "権限" do
    it "未ログインで /admin/users にアクセスするとログイン画面にリダイレクトされる" do
      get admin_users_path

      expect(response).to redirect_to new_session_path
    end

    it "一般ユーザーが /admin/users にアクセスすると 403" do
      sign_in create(:user)

      get admin_users_path

      expect(response).to have_http_status(:forbidden)
    end

    it "一般ユーザーはユーザーを作成できない" do
      sign_in create(:user)

      expect {
        post admin_users_path, params: { user: { name: "おとうさん", email_address: "father@example.com" } }
      }.not_to change { User.count }
      expect(response).to have_http_status(:forbidden)
    end

    it "管理者は一覧を表示できる" do
      admin = create(:user, :admin)
      member = create(:user, name: "おかあさん")
      sign_in admin

      get admin_users_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include member.name
    end
  end

  describe "ユーザーの追加" do
    let(:admin) { create(:user, :admin) }

    before { sign_in admin }

    it "管理者はユーザーを作成できる" do
      expect {
        post admin_users_path, params: { user: { name: "おとうさん", email_address: "father@example.com" } }
      }.to change { User.count }.by(1)

      expect(User.last.name).to eq "おとうさん"
      expect(User.last).to be_member
    end

    it "作成すると生成された初期パスワードが画面に表示される" do
      post admin_users_path, params: { user: { name: "おとうさん", email_address: "father@example.com" } }

      expect(displayed_password).to be_present
    end

    it "表示された初期パスワードでログインできる" do
      post admin_users_path, params: { user: { name: "おとうさん", email_address: "father@example.com" } }
      password = displayed_password
      sign_out

      post session_path, params: { email_address: "father@example.com", password: password }

      expect(response).to redirect_to root_url
    end

    it "初期パスワードは 1 度しか表示されない (一覧を開いても出てこない)" do
      post admin_users_path, params: { user: { name: "おとうさん", email_address: "father@example.com" } }
      password = displayed_password

      get admin_users_path

      expect(response.body).not_to include password
    end

    it "初期パスワードは flash に載せない (リダイレクトで再表示されない)" do
      post admin_users_path, params: { user: { name: "おとうさん", email_address: "father@example.com" } }

      expect(flash.to_hash.values.join).not_to include displayed_password
    end

    it "管理者として作成できる" do
      post admin_users_path, params: { user: { name: "かんりしゃ2", email_address: "admin2@example.com", role: "admin" } }

      expect(User.find_by(email_address: "admin2@example.com")).to be_admin
    end

    it "入力が不正なら作成されない" do
      expect {
        post admin_users_path, params: { user: { name: "", email_address: "father@example.com" } }
      }.not_to change { User.count }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "初期パスワードの画面はブラウザにキャッシュさせない" do
      post admin_users_path, params: { user: { name: "おとうさん", email_address: "father@example.com" } }

      expect(response_cache_control).to include "no-store"
    end

    it "初期パスワードの画面は Turbo のスナップショットにも残さない (戻るで再表示されない)" do
      post admin_users_path, params: { user: { name: "おとうさん", email_address: "father@example.com" } }

      expect(response.parsed_body.at("meta[name='turbo-cache-control']")["content"]).to eq "no-cache"
    end

    # data-turbo=false を外すと Turbo がリダイレクトを要求し、
    # 「作成されたのに初期パスワードを誰も見ていない」状態になる
    it "追加フォームは Turbo のフォーム処理を使わない" do
      get new_admin_user_path

      expect(response.parsed_body.at("form")["data-turbo"]).to eq "false"
    end

    it "編集フォームは通常どおり Turbo で動かす" do
      member = create(:user)

      get edit_admin_user_path(member)

      expect(response.parsed_body.at("form")["data-turbo"]).to be_nil
    end
  end

  describe "ユーザーの編集" do
    let(:admin) { create(:user, :admin) }

    before { sign_in admin }

    it "表示名とメールアドレスを変更できる" do
      member = create(:user)

      patch admin_user_path(member), params: { user: { name: "おかあさん", email_address: "mother@example.com" } }

      expect(member.reload.name).to eq "おかあさん"
      expect(member.email_address).to eq "mother@example.com"
    end

    it "役割を管理者に変更できる" do
      member = create(:user)

      patch admin_user_path(member), params: { user: { name: member.name, email_address: member.email_address, role: "admin" } }

      expect(member.reload).to be_admin
    end

    it "編集ではパスワードを変更できない (再設定からのみ)" do
      member = create(:user)

      patch admin_user_path(member),
        params: { user: { name: member.name, email_address: member.email_address, password: "new-family-password" } }

      expect(member.reload.authenticate("new-family-password")).to be false
    end

    it "編集では無効化できない (無効化の操作からのみ)" do
      member = create(:user)

      patch admin_user_path(member),
        params: { user: { name: member.name, email_address: member.email_address, deactivated_at: Time.current } }

      expect(member.reload).not_to be_deactivated
    end

    it "管理者が 1 人のとき、その管理者は降格できない" do
      patch admin_user_path(admin), params: { user: { name: admin.name, email_address: admin.email_address, role: "member" } }

      expect(admin.reload).to be_admin
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "管理者が 2 人いれば降格できる" do
      other_admin = create(:user, :admin)

      patch admin_user_path(other_admin),
        params: { user: { name: other_admin.name, email_address: other_admin.email_address, role: "member" } }

      expect(other_admin.reload).to be_member
    end
  end
end
