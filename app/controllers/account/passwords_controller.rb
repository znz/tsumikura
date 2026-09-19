module Account
  class PasswordsController < ApplicationController
    rate_limit to: 10, within: 3.minutes, only: :update,
      with: -> { redirect_to account_path, alert: "試行回数が多すぎます。しばらく待ってからやり直してください。" }

    def update
      user = Current.user

      # 本人確認として現在のパスワードを必須にする (docs/spec/05-auth.md)
      unless user.authenticate(params[:current_password].to_s)
        return redirect_to account_path, alert: "現在のパスワードが違います。"
      end

      attributes = params.permit(:password, :password_confirmation)

      # has_secure_password は空文字の代入を黙って無視するので、ここで弾かないと
      # 何も変わっていないのに「変更しました」になる
      if attributes[:password].blank?
        return redirect_to account_path, alert: "新しいパスワードを入力してください。"
      end

      if user.update(attributes)
        # パスワードが漏れていた場合に備え、このデバイス以外はログアウトさせる
        user.sessions.where.not(id: Current.session.id).destroy_all
        redirect_to account_path, notice: "パスワードを変更しました。ほかのデバイスはログアウトしました。"
      else
        redirect_to account_path, alert: user.errors.full_messages.to_sentence
      end
    end
  end
end
