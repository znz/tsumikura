module Admin
  class DeactivationsController < BaseController
    before_action :set_user

    def create
      if @user.update(deactivated_at: Time.current)
        # 無効化した時点で既存セッションも失効させる (docs/spec/05-auth.md)
        @user.sessions.destroy_all
        redirect_to admin_users_path, notice: "#{@user.name} を無効化しました。"
      else
        redirect_to admin_users_path, alert: @user.errors.full_messages.to_sentence
      end
    end

    def destroy
      if @user.update(deactivated_at: nil)
        redirect_to admin_users_path, notice: "#{@user.name} を再有効化しました。", status: :see_other
      else
        redirect_to admin_users_path, alert: @user.errors.full_messages.to_sentence, status: :see_other
      end
    end

    private
      def set_user
        @user = User.find_by_param!(params[:user_id])
      end
  end
end
