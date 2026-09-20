module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end

    # 無効化されたユーザーのセッションは復元しない (docs/spec/05-auth.md)
    def find_session_by_cookie
      Session.active.find_by(id: cookies.signed[:session_id]) if cookies.signed[:session_id]
    end

    def request_authentication
      # GET / HEAD 以外の URL を覚えても、ログイン後にそこへ GET すると 404 になるだけなので保存しない
      session[:return_to_after_authenticating] = request.url if request.get? || request.head?
      redirect_to new_session_path
    end

    def after_authentication_url
      session.delete(:return_to_after_authenticating) || root_url
    end

    # ログインの手順そのもの。パスワードでもパスキーでも同じ経路を通す。
    # セッション固定攻撃の対策で reset_session し、そこで消える復帰先を**先に**読み出す
    # (docs/spec/05-auth.md 4 節)
    def start_authenticated_session_for(user)
      url = after_authentication_url
      reset_session
      start_new_session_for user

      url
    end

    def start_new_session_for(user)
      user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
        Current.session = session
        cookies.signed.permanent[:session_id] = { value: session.id, httponly: true, same_site: :lax }
      end
    end

    def terminate_session
      Current.session.destroy
      cookies.delete(:session_id)
      # ログアウト後に古い Rails セッションを引き継がせない (flash はこのあとに積む)
      reset_session
    end
end
