require "rails_helper"

RSpec.describe WebPushDeliveryJob, type: :job do
  include ActiveJob::TestHelper

  let!(:subscription) { create(:web_push_subscription) }
  let(:payload) do
    { title: "つみくら", options: { body: "購入推奨 1 件 — といれっとぺーぱー", data: { path: "/" } } }
  end

  before { configure_vapid }

  # 実際の Push サービスには接続しない。例外は gem が投げるものと同じ形で作る
  def push_error(klass)
    klass.new(Struct.new(:body).new("push service said no"), "push.example.com")
  end

  def deliver(id = subscription.id)
    described_class.perform_now(id, payload)
  end

  describe "送信" do
    before { allow(WebPush).to receive(:payload_send) }

    it "購読の endpoint と鍵、VAPID、JSON にした payload を渡す" do
      deliver

      expect(WebPush).to have_received(:payload_send).with(
        endpoint: subscription.endpoint,
        p256dh: subscription.p256dh_key,
        auth: subscription.auth_key,
        message: payload.to_json,
        vapid: VapidHelper::VAPID_KEYS,
        ttl: described_class::TTL,
        urgency: described_class::URGENCY,
        open_timeout: described_class::OPEN_TIMEOUT,
        read_timeout: described_class::READ_TIMEOUT,
        ssl_timeout: described_class::OPEN_TIMEOUT
      )
    end

    it "タイムアウトを指定する (Net::HTTP 既定の 60 + 60 秒でワーカーを塞がない)" do
      expect(described_class::OPEN_TIMEOUT).to be <= 10
      expect(described_class::READ_TIMEOUT).to be <= 15
    end

    it "TTL は控えめ (1 日 1 通のダイジェストなので翌朝まで残さない)" do
      expect(described_class::TTL).to be <= 1.day.to_i
    end

    it "成功すると最終配信が入り、失敗回数が 0 に戻る" do
      subscription.record_failure!

      deliver

      expect(subscription.reload).to have_attributes(failure_count: 0)
      expect(subscription.reload.last_delivered_at).to be_present
    end

    it "鍵が未設定なら何もしない (毎朝ジョブが失敗し続けないように)" do
      unconfigure_vapid

      deliver

      expect(WebPush).not_to have_received(:payload_send)
    end

    it "購読が先に消えていても落ちない" do
      missing_id = subscription.id
      subscription.destroy!

      expect { deliver(missing_id) }.not_to raise_error
      expect(WebPush).not_to have_received(:payload_send)
    end
  end

  describe "失効した購読 (404 / 410)" do
    it "410 (ExpiredSubscription) では購読を削除する" do
      allow(WebPush).to receive(:payload_send).and_raise(push_error(WebPush::ExpiredSubscription))

      expect { deliver }.to change(WebPushSubscription, :count).by(-1)
    end

    it "404 (InvalidSubscription) でも購読を削除する" do
      allow(WebPush).to receive(:payload_send).and_raise(push_error(WebPush::InvalidSubscription))

      expect { deliver }.to change(WebPushSubscription, :count).by(-1)
    end

    it "削除したあと再送はしない" do
      allow(WebPush).to receive(:payload_send).and_raise(push_error(WebPush::ExpiredSubscription))

      expect { deliver }.not_to have_enqueued_job(described_class)
    end
  end

  describe "鍵の不一致 (401 / 403)" do
    before { allow(WebPush).to receive(:payload_send).and_raise(push_error(WebPush::Unauthorized)) }

    it "購読は削除しない (鍵を戻せば復活するため)" do
      expect { deliver }.not_to change(WebPushSubscription, :count)
    end

    it "失敗回数だけを増やす" do
      expect { deliver }.to change { subscription.reload.failure_count }.from(0).to 1
    end

    it "再送はしない (設定の問題なので繰り返しても直らない)" do
      expect { deliver }.not_to have_enqueued_job(described_class)
    end

    it "ログに endpoint を出さない" do
      messages = []
      allow(Rails.logger).to receive(:error) { |message| messages << message }

      deliver

      expect(messages.join).to include "WebPush::Unauthorized"
      expect(messages.join).not_to include subscription.endpoint
      expect(messages.join).not_to include VapidHelper::VAPID_KEYS.fetch(:private_key)
    end
  end

  describe "一時的な失敗 (429 / 5xx)" do
    it "429 (TooManyRequests) は再送される" do
      allow(WebPush).to receive(:payload_send).and_raise(push_error(WebPush::TooManyRequests))

      expect { deliver }.to have_enqueued_job(described_class)
    end

    it "5xx (PushServiceError) も再送される" do
      allow(WebPush).to receive(:payload_send).and_raise(push_error(WebPush::PushServiceError))

      expect { deliver }.to have_enqueued_job(described_class)
    end

    it "購読は削除しない" do
      allow(WebPush).to receive(:payload_send).and_raise(push_error(WebPush::PushServiceError))

      expect { deliver }.not_to change(WebPushSubscription, :count)
    end

    it "失敗回数を増やす" do
      allow(WebPush).to receive(:payload_send).and_raise(push_error(WebPush::TooManyRequests))

      expect { deliver }.to change { subscription.reload.failure_count }.from(0).to 1
    end
  end

  describe "ネットワークの失敗" do
    # 朝 8 時に DNS が一瞬途切れただけでその日の悪化が二度と通知されないのを防ぐ。
    # state は送信の成否によらず更新されるので、ここで諦めると取り返しがつかない
    described_class::NETWORK_ERRORS.each do |error_class|
      it "#{error_class} は再送される" do
        allow(WebPush).to receive(:payload_send).and_raise(error_class)

        expect { deliver }.to have_enqueued_job(described_class)
      end
    end

    it "購読は削除しない" do
      allow(WebPush).to receive(:payload_send).and_raise(Net::OpenTimeout)

      expect { deliver }.not_to change(WebPushSubscription, :count)
    end

    it "タイムアウトの一覧にはタイムアウトと接続の失敗が入っている" do
      expect(described_class::NETWORK_ERRORS)
        .to include(Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET,
          Errno::ECONNREFUSED, Errno::EHOSTUNREACH, OpenSSL::SSL::SSLError)
    end
  end

  describe "再送を諦めたとき" do
    before do
      allow(WebPush).to receive(:payload_send).and_raise(push_error(WebPush::PushServiceError))
    end

    # 例外を上げると solid_queue_failed_executions に残り続け、毎朝たまっていく
    it "例外を上げず、警告ログだけ残す" do
      warnings = []
      allow(Rails.logger).to receive(:warn) { |message| warnings << message }

      expect {
        perform_enqueued_jobs(only: described_class) { deliver }
      }.not_to raise_error

      expect(warnings.join).to include "WebPush::PushServiceError"
      expect(warnings.join).not_to include subscription.endpoint
    end
  end

  describe "そのほかの失敗" do
    it "413 (PayloadTooLarge) は購読を消さずに記録だけ残す" do
      allow(WebPush).to receive(:payload_send).and_raise(push_error(WebPush::PayloadTooLarge))

      expect { deliver }.not_to change(WebPushSubscription, :count)
      expect(subscription.reload.failure_count).to eq 1
    end

    it "想定外のステータスでもジョブは落ちない" do
      allow(WebPush).to receive(:payload_send).and_raise(push_error(WebPush::ResponseError))

      expect { deliver }.not_to raise_error
      expect(subscription.reload.failure_count).to eq 1
    end

    it "購読の鍵が壊れていて暗号化できないときは購読を消す (毎朝失敗し続けない)" do
      allow(WebPush).to receive(:payload_send).and_raise(OpenSSL::PKey::PKeyError, "invalid key")

      expect { deliver }.to change(WebPushSubscription, :count).by(-1)
    end

    it "鍵の長さが足りずに ArgumentError になったときも購読を消す" do
      allow(WebPush).to receive(:payload_send).and_raise(ArgumentError, "invalid base64")

      expect { deliver }.to change(WebPushSubscription, :count).by(-1)
    end
  end
end
