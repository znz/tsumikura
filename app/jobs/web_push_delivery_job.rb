# 購読 1 件への配信 (docs/spec/04-notifications.md 3 節)。
#
# **1 購読 1 ジョブ**にする。1 ジョブで全購読を回すと、1 件の端末が遅い / 落ちているだけで
# 残りの家族に届かなくなるため。
class WebPushDeliveryJob < ApplicationJob
  queue_as :default

  # 1 日 1 通のダイジェストなので、翌朝まで滞留した通知に価値はない。
  # 端末が丸 1 日圏外でも、その日のぶんは捨てて構わない
  TTL = 12.hours.to_i
  # 画面を点けさせるほどの急ぎではない (朝 8 時の 1 通)
  URGENCY = "normal".freeze
  # Net::HTTP の既定は open 60 秒 + read 60 秒。家庭用の小さなワーカー (3 スレッド) で
  # 塞がれると他の通知まで止まるので短くする。再送は retry_on が引き受ける
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  # Push サービスに届く前で落ちる失敗。**朝 8 時に DNS が一瞬途切れただけで諦めると、
  # state は更新済みなのでその日の悪化は二度と通知されない**ので、必ず再送に載せる
  NETWORK_ERRORS = [
    Net::OpenTimeout, Net::ReadTimeout, SocketError,
    Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EHOSTUNREACH,
    OpenSSL::SSL::SSLError
  ].freeze

  # 429 / 5xx は Push サービス側の一時的な事情。指数バックオフで最大 3 回まで。
  # 諦めたときに例外を上げると solid_queue_failed_executions に残り続けるので、
  # ブロックを渡して警告ログだけにする (1 日 1 通なので、翌朝またやり直せる)
  retry_on WebPush::TooManyRequests, WebPush::PushServiceError, *NETWORK_ERRORS,
    wait: :polynomially_longer, attempts: 3 do |job, error|
    Rails.logger.warn(
      "[WebPushDeliveryJob] gave up #{error.class.name} subscription=#{job.arguments.first}"
    )
  end

  # 購読が先に消えていたら何もしない (他のジョブが 410 で消した / 画面から削除された)
  discard_on ActiveRecord::RecordNotFound

  # payload は生成済みの service-worker.js が受け取る { title, options } の形
  def perform(subscription_id, payload)
    # 鍵が無い環境では送りようがない。ここで落とすと毎朝ジョブが失敗し続ける
    return unless Vapid.configured?

    deliver(WebPushSubscription.find(subscription_id), payload)
  end

  private
    def deliver(subscription, payload)
      WebPush.payload_send(
        endpoint: subscription.endpoint,
        p256dh: subscription.p256dh_key,
        auth: subscription.auth_key,
        message: payload.to_json,
        vapid: Vapid.keys,
        ttl: TTL,
        urgency: URGENCY,
        open_timeout: OPEN_TIMEOUT,
        ssl_timeout: OPEN_TIMEOUT,
        read_timeout: READ_TIMEOUT
      )
      subscription.record_delivery!
    rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription
      # 410 / 404: 端末側で購読が失効している。残しても二度と届かないので消す。
      # 次にアカウント設定を開いたときに購読し直される
      subscription.destroy
    rescue WebPush::Unauthorized, WebPush::PayloadTooLarge => e
      # 401 / 403 (VAPID 鍵が購読時のものと違う) と 413 (本文が大きすぎる)。
      # どちらもこちら側の設定の問題で、購読自体は生きているので**消さない**
      subscription.record_failure!
      log_failure(subscription, e)
    rescue WebPush::TooManyRequests, WebPush::PushServiceError
      subscription.record_failure!
      raise # 再送は retry_on に任せる
    rescue WebPush::ResponseError => e
      # 想定外のステータス。再送しても直らないことが多いので記録だけ残す
      subscription.record_failure!
      log_failure(subscription, e)
    rescue OpenSSL::PKey::PKeyError, ArgumentError => e
      # 購読の鍵 (p256dh / auth) が壊れていて本文を暗号化できない。
      # 直しようがなく毎朝同じ失敗を繰り返すだけなので、購読を消して登録し直してもらう
      log_failure(subscription, e)
      subscription.destroy
    end

    # **endpoint も VAPID の鍵もログに出さない** (endpoint は端末を特定できる秘密)。
    # 出すのは購読の id と Push サービスのホストだけ
    def log_failure(subscription, error)
      Rails.logger.error(
        "[WebPushDeliveryJob] #{error.class.name} subscription=#{subscription.id} host=#{error.try(:host)}"
      )
    end
end
