module Account
  # ログイン中デバイスの失効。ログアウト (SessionsController#destroy) とは別に置く
  class SessionsController < ApplicationController
    def destroy
      target = Current.user.sessions.find(params[:id])

      if target.id == Current.session.id
        # 自分のデバイスを選んだときは通常のログアウトと同じ扱いにする (reset_session も行う)
        terminate_session
        redirect_to new_session_path, notice: "ログアウトしました。", status: :see_other
      else
        target.destroy
        redirect_to account_path, notice: "選んだデバイスをログアウトしました。", status: :see_other
      end
    end

    def others
      Current.user.sessions.where.not(id: Current.session.id).destroy_all
      redirect_to account_path, notice: "このデバイス以外をログアウトしました。", status: :see_other
    end
  end
end
