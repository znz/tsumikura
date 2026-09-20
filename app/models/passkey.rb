# 登録済みのパスキー (docs/spec/05-auth.md 5 節)。
#
# パスキーは**追加の認証手段**で、パスワードを置き換えるものではない。
# 1 つも持たないユーザーも普通にログインできるし、全部消してもパスワードでログインできる。
#
# external_id (credential ID) だけで行を引けるようにしてある。discoverable credential
# (resident key) で登録しているので、ログインはメールアドレスの入力なしに行われる。
class Passkey < ApplicationRecord
  # migration の limit と合わせる
  MAX_EXTERNAL_ID_LENGTH = 1400
  MAX_NICKNAME_LENGTH = 50

  # 壊れた credential を渡されたときに 500 にしないための rescue 一覧。
  # webauthn gem は検証の失敗を WebAuthn::Error で投げるが、**形が壊れた入力では
  # それ以外の例外になる**ことを実際に確かめてある:
  #   base64url として壊れている        -> ArgumentError
  #   response / キーが欠けている        -> ArgumentError / NoMethodError / TypeError
  #   type や id が食い違う              -> RuntimeError (gem の raise("invalid type"))
  #   公開鍵・attestation のデコード失敗 -> COSE::Error / CBOR::UnpackError
  # 対象は from_create / from_get / verify を呼ぶ数行だけに限る
  VERIFICATION_ERRORS = [
    WebAuthn::Error, COSE::Error, CBOR::UnpackError, OpenSSL::OpenSSLError,
    JSON::ParserError, ArgumentError, TypeError, NoMethodError, RuntimeError
  ].freeze

  belongs_to :user

  validates :external_id, presence: true, length: { maximum: MAX_EXTERNAL_ID_LENGTH }
  # allow_blank は同じ validates のすべての検証に効くので、presence とは分けて書く
  validates :external_id, uniqueness: true, allow_blank: true
  validates :public_key, presence: true
  validates :nickname, presence: true, length: { maximum: MAX_NICKNAME_LENGTH }
  validates :sign_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :recent_first, -> { order(created_at: :desc) }

  # パスキーの検証に必要な origin が設定されているか。
  # 未設定の環境では画面に登録ボタンを出さない (押しても必ず失敗するため)
  def self.available?
    WebAuthn.configuration.allowed_origins.present? && WebAuthn.configuration.rp_id.present?
  end

  # JS から届く credential (JSON 文字列) を Hash にする。
  # 文字列でない・Hash にならない入力はここで弾き、gem には渡さない。
  #
  # **id が String であることもここで確かめる。** gem は Hash や配列の id をそのまま通すので、
  # 検証の前に走る Passkey.find_by(external_id:) に配列が渡って IN 検索になってしまう
  def self.parse_credential(raw)
    raise TypeError, "credential must be a JSON string" unless raw.is_a?(String)

    JSON.parse(raw).tap do |parsed|
      raise TypeError, "credential must be a JSON object" unless parsed.is_a?(Hash)
      raise TypeError, "credential id must be a String" unless parsed["id"].is_a?(String)
    end
  end
end
