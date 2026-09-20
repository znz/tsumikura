require "base64"

# ブラウザの PushSubscription (docs/spec/04-notifications.md 3 節)。
#
# endpoint は **端末 + ブラウザに 1 つ**なので一意。同じ端末で別の家族がログインして
# 購読し直したときは行を増やさずに user_id を付け替える (upsert_for)。
class WebPushSubscription < ApplicationRecord
  # migration の limit と合わせる。endpoint は通常 200-500 バイト
  MAX_ENDPOINT_LENGTH = 2048
  MAX_KEY_LENGTH = 255
  MAX_USER_AGENT_LENGTH = 255
  # 1 人が持てる端末の数。家庭用としては十分に多い。超えたぶんは古い方から消す
  # (ここで 422 にすると、実在する端末が購読し直せなくなる方が困る)
  MAX_PER_USER = 20

  # Push サービスの endpoint は必ず https (DB の check 制約と同じ条件)。
  # 改行を含む値を通すと \A / \z の無い検証をすり抜けるので、両端まで固定する
  ENDPOINT_FORMAT = %r{\Ahttps://\S+\z}
  # p256dh / auth は base64url。パディングを付ける実装があるので = も許す
  KEY_FORMAT = /\A[A-Za-z0-9_-]+={0,2}\z/

  # **既知の Push サービスのホストだけを受け付ける。**
  # ログイン済みの家族なら誰でも endpoint を登録でき、テスト送信でサーバから任意の
  # https URL へ POST させられるため (blind SSRF と増幅)。
  # 新しいブラウザ / Push サービスに対応するときはここに足す
  # (docs/spec/04-notifications.md 3 節)
  ALLOWED_HOSTS = [
    /\Afcm\.googleapis\.com\z/,           # Chrome / Android (FCM)
    /\Aandroid\.googleapis\.com\z/,       # 旧 GCM のホスト
    /\.push\.services\.mozilla\.com\z/,   # Firefox
    /\.notify\.windows\.com\z/,           # Edge (WNS)
    /\Aweb\.push\.apple\.com\z/,          # Safari / iOS
    /\.push\.apple\.com\z/
  ].freeze

  # ブラウザが返す鍵の長さ。p256dh は非圧縮の楕円曲線の点 (先頭 0x04 + x 32 + y 32)、
  # auth は 16 バイトのシークレット。ここで弾いておかないと、配信時に
  # OpenSSL の例外になって毎朝同じ失敗を繰り返す
  P256DH_BYTES = 65
  AUTH_BYTES = 16
  UNCOMPRESSED_POINT = 0x04

  belongs_to :user

  # user_agent は端末名の代わりに出すだけなので、長すぎる値は切り詰めて通す
  # (ここで検証を落として購読できなくする方が害が大きい)
  normalizes :user_agent, with: ->(value) { value.to_s.strip.truncate(MAX_USER_AGENT_LENGTH).presence }

  # presence と length / format は別の validates にする
  # (1 つにまとめると allow_blank が presence にも掛かる)
  validates :endpoint, presence: true
  validates :endpoint, uniqueness: true, length: { maximum: MAX_ENDPOINT_LENGTH },
    format: { with: ENDPOINT_FORMAT }, allow_blank: true
  validates :p256dh_key, presence: true
  validates :p256dh_key, length: { maximum: MAX_KEY_LENGTH }, format: { with: KEY_FORMAT }, allow_blank: true
  validates :auth_key, presence: true
  validates :auth_key, length: { maximum: MAX_KEY_LENGTH }, format: { with: KEY_FORMAT }, allow_blank: true

  validate :endpoint_must_be_push_service
  validate :keys_must_be_well_formed

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  # endpoint をキーにした upsert。**保存できたかは返り値の persisted? / errors で見る**
  # (フォームからの入力なので、失敗を例外にせず 422 を返せるようにする)。
  #
  # 同じ endpoint の行が他人のものだったら付け替える = 同じ端末で別の家族がログインした場合。
  # 「消してから作る」にすると、失敗したときに購読だけが消えるので update で付け替える。
  def self.upsert_for(user:, endpoint:, p256dh:, auth:, user_agent: nil)
    attributes = {
      user: user, p256dh_key: p256dh, auth_key: auth, user_agent: user_agent,
      # 付け替え・再購読で失敗の記録は引き継がない
      failure_count: 0
    }

    record = find_or_initialize_by(endpoint: endpoint.to_s)
    record.assign_attributes(attributes)
    record.save
    prune_for(user) if record.persisted?
    record
  rescue ActiveRecord::RecordNotUnique
    # 同じ endpoint の登録が同時に 2 本走ったとき。一意制約は DB が守っているので、
    # 後から来た方は掴み直して付け替える (行は増やさない)
    existing = find_by(endpoint: endpoint.to_s)
    raise if existing.nil?

    existing.update(attributes)
    prune_for(user)
    existing
  end

  # 1 人あたりの上限を超えたぶんを古い方から消す。届かない購読をためない
  def self.prune_for(user)
    stale = where(user_id: user.id).recent_first.offset(MAX_PER_USER).pluck(:id)

    where(id: stale).delete_all if stale.any?
  end

  def record_delivery!
    # 検証もコールバックも要らない更新なので update_columns で 1 本の UPDATE にする
    update_columns(last_delivered_at: Time.current, failure_count: 0, updated_at: Time.current)
  end

  def record_failure!
    self.class.update_counters(id, failure_count: 1, touch: true)
  end

  private
    def endpoint_must_be_push_service
      return if endpoint.blank?

      errors.add(:endpoint, :invalid) unless push_service_endpoint?
    end

    def push_service_endpoint?
      # 非 ASCII は URI でも btree の index でも壊れるので、読む前に落とす
      return false unless endpoint.ascii_only?

      uri = URI.parse(endpoint)
      uri.is_a?(URI::HTTPS) && uri.port == 443 && ALLOWED_HOSTS.any? { _1.match?(uri.host.to_s) }
    rescue URI::InvalidURIError
      # 読めない endpoint は配信時に URI::InvalidURIError になり、例外メッセージに
      # endpoint 全文が入ってログに残る。ここで検証エラーにして入れさせない
      false
    end

    def keys_must_be_well_formed
      errors.add(:p256dh_key, :invalid) if p256dh_key.present? && !valid_p256dh_key?
      errors.add(:auth_key, :invalid) if auth_key.present? && !valid_auth_key?
    end

    def valid_p256dh_key?
      bytes = decode_key(p256dh_key)

      bytes&.bytesize == P256DH_BYTES && bytes.getbyte(0) == UNCOMPRESSED_POINT
    end

    def valid_auth_key?
      decode_key(auth_key)&.bytesize == AUTH_BYTES
    end

    def decode_key(value)
      Base64.urlsafe_decode64(value.to_s)
    rescue ArgumentError
      nil
    end
end
