FactoryBot.define do
  factory :web_push_subscription do
    user
    # Push サービスが払い出す URL。端末 + ブラウザに 1 つなので一意。
    # ホストは許可リスト (WebPushSubscription::ALLOWED_HOSTS) に載っているものを使う
    sequence(:endpoint) { |n| "https://fcm.googleapis.com/fcm/send/spec-subscription-#{n}" }
    # ブラウザが返すのと同じ長さ (65 バイトの非圧縮点 / 16 バイト) にする
    p256dh_key { Base64.urlsafe_encode64([ 4 ].pack("C") + SecureRandom.bytes(64)) }
    auth_key { Base64.urlsafe_encode64(SecureRandom.bytes(16)) }
    user_agent do
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 " \
        "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    end

    trait :delivered do
      last_delivered_at { Time.current }
    end
  end
end
