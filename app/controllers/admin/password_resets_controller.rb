module Admin
  class PasswordResetsController < BaseController
    before_action :set_user
    before_action :redirect_self_to_account

    def new
      @passkey_count = @user.passkeys.count
    end

    def create
      @generated_password = User.generate_password

      # 途中で失敗して「パスワードは変わったがセッションは生きている」状態を作らない。
      # **順番にも意味がある**: 先にセッションを消すと、パスキーを消すまでの隙に
      # パスキーでログインされて新しいセッションが残る。認証手段を先に潰す
      User.transaction do
        @user.update!(password: @generated_password)
        # パスキーも消す。パスワードの再設定は「乗っ取られたかもしれない」ときの操作でもあり、
        # パスキーを残すと攻撃者が登録したパスキーで入り続けられる (パスワードを変えても失効しない)。
        # 本人は新しいパスワードでログインしてから /account で登録し直す
        @removed_passkey_count = @user.passkeys.destroy_all.size
        # 再設定したら本人のセッションはすべて失効させる (docs/spec/05-auth.md)
        @user.sessions.destroy_all
      end

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
