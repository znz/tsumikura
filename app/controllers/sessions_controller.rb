class SessionsController < ApplicationController
  INVALID_CREDENTIALS_MESSAGE = "メールアドレスまたはパスワードが違います。".freeze

  allow_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create,
    with: -> { redirect_to new_session_path, alert: "試行回数が多すぎます。しばらく待ってからやり直してください。" }

  def new
  end

  def create
    # expect は値が欠けていたりスカラーでなかったりすると 400 にする
    # (authenticate_by に渡すと ArgumentError で 500 になるため)
    email_address, password = params.expect(:email_address, :password)
    user = User.authenticate_by(email_address: email_address, password: password)

    # 無効化されたユーザーはパスワードが正しくてもログインさせない。
    # 無効化されていることは伏せ、パスワード誤りと同じ文言を返す
    if user && !user.deactivated?
      redirect_to start_authenticated_session_for(user)
    else
      redirect_to new_session_path, alert: INVALID_CREDENTIALS_MESSAGE
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, notice: "ログアウトしました。", status: :see_other
  end
end
