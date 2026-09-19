module Admin
  class PasswordResetsController < BaseController
    before_action :set_user
    before_action :redirect_self_to_account

    def new
    end

    def create
      @generated_password = User.generate_password
      @user.update!(password: @generated_password)
      # 再設定したら本人のセッションはすべて失効させる (docs/spec/05-auth.md)
      @user.sessions.destroy_all
      # 新しいパスワードは 1 度だけ見せる (リダイレクトも flash も使わず、キャッシュにも残さない)
      no_store
    end

    private
      def set_user
        @user = User.find(params[:user_id])
      end

      # 自分に対して実行すると自分のセッションまで消えて操作中にログアウトする。
      # 自分のパスワードはアカウント設定 (現在のパスワードの確認つき) から変える
      def redirect_self_to_account
        return unless @user == Current.user

        redirect_to account_path, alert: "自分のパスワードはアカウント設定から変更してください。"
      end
  end
end
