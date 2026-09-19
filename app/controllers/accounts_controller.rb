class AccountsController < ApplicationController
  before_action :set_user

  def show
    @sessions = login_sessions
  end

  def update
    if @user.update(account_params)
      redirect_to account_path, notice: "アカウント情報を更新しました。"
    else
      @sessions = login_sessions
      render :show, status: :unprocessable_content
    end
  end

  private
    def set_user
      @user = Current.user
    end

    def login_sessions
      @user.sessions.order(created_at: :desc)
    end

    # 役割 (role) と無効化 (deactivated_at) は管理者だけが変えられる
    def account_params
      params.expect(user: [ :name, :email_address ])
    end
end
