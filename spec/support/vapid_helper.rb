# VAPID 鍵は環境変数から読む (config/initializers/web_push.rb) ので、test 環境には入っていない。
# 実際の Push サービスには接続しない (WebPush.payload_send は stub する) ので、鍵はダミーで足りる。
#
# 既定を「未設定」のままにしてあるのは、鍵が無い環境の振る舞い (画面の案内・ジョブが黙って
# 終わること) も spec で固定するため。鍵が要る例では configure_vapid を呼ぶ。
module VapidHelper
  VAPID_KEYS = {
    public_key: "BTestPublicKeyForSpecsOnly",
    private_key: "TestPrivateKeyForSpecsOnly",
    subject: "mailto:test@example.com"
  }.freeze

  def configure_vapid(keys = VAPID_KEYS)
    allow(Vapid).to receive(:keys).and_return(keys)
  end

  def unconfigure_vapid
    allow(Vapid).to receive(:keys).and_return(subject: "mailto:test@example.com")
  end
end

RSpec.configure do |config|
  config.include VapidHelper
end
