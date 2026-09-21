# パスキーの登録と削除 (docs/spec/05-auth.md 5 節)。一覧は /account に統合している。
#
# **登録には現在のパスワードの再確認を求める。** 05-auth.md は登録フローに書いていないが、
# セッションを盗んだ者が自分のパスキーを足して永続化できてしまうため (パスキーは
# パスワードを変えても失効しない)、challenge を出す前にパスワードを確かめる。
# challenge が無ければ create は必ず失敗するので、確認は options の 1 か所で足りる。
class PasskeysController < ApplicationController
  include WebauthnChallenge

  # 未ログインのログイン用 challenge (Sessions::PasskeysController) と**必ず別のキー**にする。
  # 同じキーだと、セッションを盗んだ者がパスワードなしで登録用 challenge を手に入れられる
  CHALLENGE_SESSION_KEY = :passkey_registration_challenge
  # 登録は画面を開いてすぐ行う操作なので短くてよい。生体認証をキャンセルしたまま残った
  # challenge を、Cookie を盗んだ者に使われる時間を切り詰める
  CHALLENGE_TTL = 5.minutes

  REGISTRATION_FAILED_MESSAGE = "パスキーを登録できませんでした。もう一度お試しください。".freeze

  # options は現在のパスワードを見るので、パスワード変更と同じ制限を掛ける。
  # 複数の rate_limit を 1 つのコントローラに置くときは name: で分ける
  # (付けないと同じキーを取り合う)
  rate_limit to: 10, within: 3.minutes, only: :options, name: "options",
    with: -> { render_rate_limited }
  rate_limit to: 10, within: 3.minutes, only: :create, name: "create",
    with: -> { render_rate_limited }

  # 登録の開始。現在のパスワードを確かめてから challenge を発行する
  def options
    unless Current.user.authenticate(params[:current_password].to_s)
      return render json: { error: "現在のパスワードが違います。" }, status: :unauthorized
    end

    options = WebAuthn::Credential.options_for_create(
      user: {
        id: Current.user.ensure_webauthn_id!,
        name: Current.user.email_address,
        display_name: Current.user.name
      },
      # 同じ認証器に 2 つ目を作らせない (ブラウザが「登録済み」と教えてくれる)
      exclude: Current.user.passkeys.pluck(:external_id),
      # resident_key: required = discoverable credential (メール入力なしのログインに要る)。
      # user_verification: required = 生体認証か PIN を必ず通す。パスキーだけでログインできる以上、
      # 「持っているだけ」で入れてはいけない (PIN 無しのセキュリティキー対策)
      authenticator_selection: { resident_key: "required", user_verification: "required" }
    )

    issue_webauthn_challenge(CHALLENGE_SESSION_KEY, options.challenge)
    render json: options
  end

  def create
    # challenge は 1 回限り。失敗しても捨てる (再利用で総当たりされないように)
    challenge = consume_webauthn_challenge(CHALLENGE_SESSION_KEY, CHALLENGE_TTL)
    credential = verified_credential(challenge)

    return render_registration_failure unless credential

    # user_id / external_id / public_key / sign_count はフォームからは設定できない
    passkey = Current.user.passkeys.create!(
      external_id: credential.id,
      public_key: credential.public_key,
      sign_count: credential.sign_count,
      nickname: nickname
    )

    # id は URL に入れうる値なので Base58 の 22 文字で返す (docs/spec/03-screens.md)
    render json: { id: passkey.to_param, nickname: passkey.nickname }, status: :created
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    # 同じ credential ID が既にある (unique index) など
    render_registration_failure
  end

  def destroy
    # 他人のパスキーは消せない (id は Current.user のぶんだけを引く)。
    # 既に消えているパスキー (古い画面・別の端末で削除済み) は 404 にせず成功として扱う
    Current.user.passkeys.find_by_param(params[:id])&.destroy

    redirect_to account_path, notice: "パスキーを削除しました。"
  end

  private
    # 検証に通った credential を返す。だめなら nil。
    # **広い rescue は gem を呼ぶ数行だけ**に閉じ込める (保存まで巻き込むと、
    # 本物の不具合を静かな 422 に変えてしまう)
    def verified_credential(challenge)
      credential = parsed_attestation
      return nil unless credential
      return nil unless attestation_valid?(credential, challenge)

      credential
    end

    def parsed_attestation
      WebAuthn::Credential.from_create(Passkey.parse_credential(params[:credential]))
    rescue *Passkey::VERIFICATION_ERRORS
      nil
    end

    def attestation_valid?(credential, challenge)
      # user_verification: true で「生体認証か PIN を通したこと」を必須にする
      credential.verify(challenge, user_verification: true)
    rescue *Passkey::VERIFICATION_ERRORS
      false
    end

    def render_registration_failure
      render json: { error: REGISTRATION_FAILED_MESSAGE }, status: :unprocessable_content
    end

    def render_rate_limited
      render json: { error: "試行回数が多すぎます。しばらく待ってからやり直してください。" },
        status: :too_many_requests
    end

    # 名前は任意入力。空なら User-Agent から「iPhone / Safari」くらいの見出しを付ける。
    # 配列やハッシュで送られたときは入力が無かったものとして扱う (to_s の中身を名前にしない)
    def nickname
      submitted = params[:nickname].is_a?(String) ? params[:nickname].strip : ""

      submitted.presence&.truncate(Passkey::MAX_NICKNAME_LENGTH) ||
        helpers.push_device_label(request.user_agent)
    end
end
