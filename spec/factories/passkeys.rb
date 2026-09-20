FactoryBot.define do
  # 検証には使えない「行だけ」のパスキー。実際のログインを試す spec は
  # spec/support/webauthn_helper.rb の FakeClient で本物の credential を作ること
  factory :passkey do
    user
    sequence(:external_id) { |n| "credential-#{n}-#{SecureRandom.urlsafe_base64(16)}" }
    public_key { SecureRandom.urlsafe_base64(64) }
    nickname { "テストの端末" }
    sign_count { 0 }
  end
end
