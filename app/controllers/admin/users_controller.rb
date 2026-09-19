module Admin
  class UsersController < BaseController
    before_action :set_user, only: %i[ edit update ]

    def index
      @users = User.order(:id)
    end

    def new
      @user = User.new
    end

    def create
      @user = User.new(user_params)
      @generated_password = User.generate_password
      @user.password = @generated_password

      if @user.save
        # 初期パスワードは 1 度だけ見せる。リダイレクトも flash も使わず、
        # ブラウザにも中間キャッシュにも残さない
        no_store
        render :created
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit
    end

    def update
      if @user.update(user_params)
        redirect_to admin_users_path, notice: "#{@user.name} の情報を更新しました。"
      else
        render :edit, status: :unprocessable_content
      end
    end

    private
      def set_user
        @user = User.find(params[:id])
      end

      # 無効化 (deactivated_at) は Admin::DeactivationsController、
      # パスワードは Admin::PasswordResetsController の担当なのでここでは受け取らない
      def user_params
        params.expect(user: [ :name, :email_address, :role ])
      end
  end
end
