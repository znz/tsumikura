require "rails_helper"

# 管理画面の全アクションを表で総当たりする。権限昇格はここが最後の砦なので、
# アクションを足したらこの表にも足すこと。
# パスとパラメータは example の中で評価する (actor / target は let)。
admin_actions = [
  [ "ユーザー一覧", :get, -> { admin_users_path }, -> { {} } ],
  [ "ユーザー追加フォーム", :get, -> { new_admin_user_path }, -> { {} } ],
  [ "ユーザー追加", :post, -> { admin_users_path },
    -> { { user: { name: "しんき", email_address: "intruder@example.com", role: "admin" } } } ],
  [ "ユーザー編集フォーム", :get, -> { edit_admin_user_path(target) }, -> { {} } ],
  [ "自分を管理者に更新", :patch, -> { admin_user_path(actor) },
    -> { { user: { name: actor.name, email_address: actor.email_address, role: "admin" } } } ],
  [ "他人を編集", :patch, -> { admin_user_path(target) },
    -> { { user: { name: "のっとり", email_address: target.email_address, role: "admin" } } } ],
  [ "パスワード再設定フォーム", :get, -> { new_admin_user_password_reset_path(target) }, -> { {} } ],
  [ "パスワード再設定", :post, -> { admin_user_password_reset_path(target) }, -> { {} } ],
  [ "無効化", :post, -> { admin_user_deactivation_path(target) }, -> { {} } ],
  [ "再有効化", :delete, -> { admin_user_deactivation_path(target) }, -> { {} } ]
]

RSpec.describe "管理画面の認可", type: :request do
  let(:actor) { create(:user) }
  let(:target) { create(:user, name: "おかあさん") }

  # def はブロックの外側のローカル変数を閉じ込められないので let 経由で渡す
  let(:all_actions) { admin_actions }

  def request_admin_action(verb, path, params)
    public_send(verb, instance_exec(&path), params: instance_exec(&params))
  end

  def request_all_admin_actions
    all_actions.each { |_name, verb, path, params| request_admin_action(verb, path, params) }
  end

  describe "一般ユーザー" do
    before { sign_in actor }

    admin_actions.each do |name, verb, path, params|
      it "#{name} は 403 で拒否される" do
        request_admin_action(verb, path, params)

        expect(response).to have_http_status(:forbidden)
      end
    end

    it "すべて叩いても自分は管理者にならず、無効化もされない" do
      request_all_admin_actions

      expect(actor.reload).to be_member
      expect(actor.reload).not_to be_deactivated
    end

    it "すべて叩いても他人の役割・状態・パスワード・表示名は変わらない" do
      target

      request_all_admin_actions

      expect(target.reload).to be_member
      expect(target).not_to be_deactivated
      expect(target.name).to eq "おかあさん"
      expect(target.authenticate("family-password")).to be_truthy
    end

    it "すべて叩いてもユーザーは増えない" do
      actor
      target

      expect { request_all_admin_actions }.not_to change { User.count }
    end
  end

  describe "未ログイン" do
    admin_actions.each do |name, verb, path, params|
      it "#{name} はログイン画面にリダイレクトされる" do
        request_admin_action(verb, path, params)

        expect(response).to redirect_to new_session_path
      end
    end

    it "すべて叩いてもユーザーは増えず、既存ユーザーも変わらない" do
      actor
      target

      expect { request_all_admin_actions }.not_to change { User.count }
      expect(target.reload).to be_member
      expect(target).not_to be_deactivated
    end
  end

  describe "管理者" do
    before { sign_in create(:user, :admin) }

    admin_actions.each do |name, verb, path, params|
      it "#{name} は 403 にならない" do
        request_admin_action(verb, path, params)

        expect(response).not_to have_http_status(:forbidden)
      end
    end
  end
end
