module Sessions
  # パスキーでのログイン (docs/spec/05-auth.md 5 節)。
  #
  # discoverable credential (resident key) で登録しているので allow_credentials は渡さない。
  # メールアドレスの入力なしに、端末が持っているパスキーから選んでもらう (usernameless)。
  #
  # **失敗はすべて同じ文言・同じステータスで返す。** credential の有無・検証の失敗・
  # ユーザーの無効化を区別すると、パスキーの登録状況やアカウントの存在が分かってしまう。
  class PasskeysController < ApplicationController
    include WebauthnChallenge

    # 登録用の challenge (PasskeysController) と**必ず別のキー**にする。
    # 同じキーだと、この未ログインのエンドポイントで発行した challenge を
    # パスワードの再確認なしの登録に使い回せてしまう
    CHALLENGE_SESSION_KEY = :passkey_authentication_challenge
    # conditional UI はログイン画面を開いた時点で ceremony を始め、家族が
    # メール欄をタップするまで待つ。登録より長めに取る
    CHALLENGE_TTL = 15.minutes

    FAILED_MESSAGE = "パスキーでログインできませんでした。パスワードでログインしてください。".freeze

    allow_unauthenticated_access

    # 未ログインで叩けるので、どちらにも制限を掛ける。
    # 複数の rate_limit を 1 つのコントローラに置くときは name: で分ける (付けないとキーを取り合う)。
    #
    # options は conditional UI のためにログイン画面を開くたびに 1 回呼ばれる。
    # 家族全員が同じ回線 (= 同じ IP) から来るので、ログインの試行より多めに取る。
    # challenge を配るだけで、当てるにはパスキーの秘密鍵が要る
    rate_limit to: 30, within: 3.minutes, only: :options, name: "options",
      with: -> { render_rate_limited }
    # create はログインの試行そのものなので、パスワードログインと同じ 10 回 / 3 分
    rate_limit to: 10, within: 3.minutes, only: :create, name: "create",
      with: -> { render_rate_limited }

    def options
      # user_verification: required = 生体認証か PIN を必ず通す。
      # パスキー 1 つでログインできる以上、「持っているだけ」で入れてはいけない
      options = WebAuthn::Credential.options_for_get(user_verification: "required")

      issue_webauthn_challenge(CHALLENGE_SESSION_KEY, options.challenge)
      render json: options
    end

    def create
      # challenge は 1 回限り。期限切れ・使用済み・未発行なら nil になり、verify が必ず失敗する
      challenge = consume_webauthn_challenge(CHALLENGE_SESSION_KEY, CHALLENGE_TTL)
      passkey = verified_passkey(challenge)

      return render_rejection unless passkey
      # 無効化されたユーザーはパスワードと同じく入れない (docs/spec/05-auth.md 4 節)
      return render_rejection if passkey.user.deactivated?

      # パスワードログインと同じ経路 (reset_session を含む) を通す
      render json: { redirect_url: start_authenticated_session_for(passkey.user) }
    end

    private
      # credential を検証して Passkey を返す。見つからない・検証に失敗した・
      # 入力が壊れているときは nil。
      # **広い rescue は gem を呼ぶ数行だけ**に閉じ込める (DB 操作やログインの手順まで
      # 巻き込むと、本物の不具合を静かな 401 に変えてしまう)
      def verified_passkey(challenge)
        credential = parsed_assertion
        return nil unless credential

        passkey = Passkey.find_by(external_id: credential.id)
        return nil unless passkey
        return nil unless assertion_valid?(credential, challenge, passkey)
        # 認証器が user handle を返したなら、登録時のものと一致すること
        # (別のユーザーの credential ID を混ぜられないように)
        return nil if credential.user_handle.present? && credential.user_handle != passkey.user.webauthn_id

        # クローン検知のカウンタは、このあと断る場合でも進めておく
        passkey.update!(sign_count: credential.sign_count, last_used_at: Time.current)

        passkey
      end

      def parsed_assertion
        WebAuthn::Credential.from_get(Passkey.parse_credential(params[:credential]))
      rescue *Passkey::VERIFICATION_ERRORS
        nil
      end

      def assertion_valid?(credential, challenge, passkey)
        credential.verify(
          challenge,
          public_key: passkey.public_key,
          sign_count: passkey.sign_count,
          # user_verification: true で「生体認証か PIN を通したこと」を必須にする
          user_verification: true
        )
      rescue *Passkey::VERIFICATION_ERRORS
        false
      end

      def render_rejection
        render json: { error: FAILED_MESSAGE }, status: :unauthorized
      end

      def render_rate_limited
        render json: { error: "試行回数が多すぎます。しばらく待ってからやり直してください。" },
          status: :too_many_requests
      end
  end
end
