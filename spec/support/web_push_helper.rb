# Web Push の購読の値を作るヘルパー。
#
# endpoint は Push サービスのホストの許可リスト (WebPushSubscription::ALLOWED_HOSTS) を通る形、
# 鍵はブラウザが返すのと同じ長さ (p256dh は 65 バイトの非圧縮点、auth は 16 バイト) にする。
module WebPushHelper
  def push_endpoint(token = SecureRandom.alphanumeric(24))
    "https://fcm.googleapis.com/fcm/send/#{token}"
  end

  # 先頭の 0x04 は「非圧縮の楕円曲線の点」の印
  def push_p256dh
    Base64.urlsafe_encode64([ 4 ].pack("C") + SecureRandom.bytes(64))
  end

  def push_auth
    Base64.urlsafe_encode64(SecureRandom.bytes(16))
  end
end

RSpec.configure do |config|
  config.include WebPushHelper
end
