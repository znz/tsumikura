module Admin
  class BaseController < ApplicationController
    before_action :require_admin

    private
      # 在庫データに権限差は設けず、管理者だけがユーザー管理できる (docs/spec/05-auth.md)
      def require_admin
        head :forbidden unless Current.user.admin?
      end
  end
end
