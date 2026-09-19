require "rails_helper"

RSpec.describe "ユーザーの無効化", type: :request do
  let(:admin) { create(:user, :admin) }

  describe "権限" do
    it "一般ユーザーは他人を無効化できない" do
      sign_in create(:user)
      target = create(:user)

      post admin_user_deactivation_path(target)

      expect(response).to have_http_status(:forbidden)
      expect(target.reload).not_to be_deactivated
    end
  end

  describe "POST (無効化)" do
    before { sign_in admin }

    it "管理者はユーザーを無効化できる" do
      member = create(:user)

      post admin_user_deactivation_path(member)

      expect(member.reload).to be_deactivated
      expect(response).to redirect_to admin_users_path
    end

    it "無効化すると対象ユーザーのログイン中セッションがすべて失効する" do
      member = create(:user)
      member.sessions.create!(ip_address: "127.0.0.1", user_agent: "rspec")
      member.sessions.create!(ip_address: "127.0.0.2", user_agent: "rspec")

      expect { post admin_user_deactivation_path(member) }.to change { member.sessions.count }.to(0)
    end

    it "管理者が 1 人のとき、その管理者は無効化できない" do
      post admin_user_deactivation_path(admin)

      expect(admin.reload).not_to be_deactivated
      expect(flash[:alert]).to be_present
    end

    it "管理者が 2 人いれば無効化できる" do
      other_admin = create(:user, :admin)

      post admin_user_deactivation_path(other_admin)

      expect(other_admin.reload).to be_deactivated
    end

    it "一覧には自分の行の無効化ボタンを出さない (自分をロックアウトする導線を作らない)" do
      member = create(:user)

      get admin_users_path

      expect(response.body).to include admin_user_deactivation_path(member)
      expect(response.body).not_to include admin_user_deactivation_path(admin)
    end
  end

  describe "DELETE (再有効化)" do
    before { sign_in admin }

    it "無効化されたユーザーを再有効化できる" do
      member = create(:user, :deactivated)

      delete admin_user_deactivation_path(member)

      expect(member.reload).not_to be_deactivated
    end

    it "再有効化するとログインできるようになる" do
      member = create(:user, :deactivated)
      delete admin_user_deactivation_path(member)
      sign_out

      sign_in member

      expect(response).to redirect_to root_url
    end
  end
end
