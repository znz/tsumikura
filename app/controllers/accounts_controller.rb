class AccountsController < ApplicationController
  before_action :set_user

  def show
    load_show
  end

  def update
    if @user.update(account_params)
      redirect_to account_path, notice: "アカウント情報を更新しました。"
    else
      load_show
      render :show, status: :unprocessable_content
    end
  end

  private
    def set_user
      @user = Current.user
    end

    def load_show
      @sessions = login_sessions
      # 通知を受け取る端末 (docs/spec/04-notifications.md 3 節)
      @push_subscriptions = @user.web_push_subscriptions.recent_first
      # 登録済みのパスキー (docs/spec/05-auth.md 5 節)
      @passkeys = @user.passkeys.recent_first
    end

    def login_sessions
      @user.sessions.order(created_at: :desc)
    end

    # 役割 (role) と無効化 (deactivated_at) は管理者だけが変えられる
    def account_params
      params.expect(user: [ :name, :email_address ])
    end
end
