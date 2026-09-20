require "rails_helper"

RSpec.describe WebPushSubscription do
  let(:user) { create(:user) }

  describe "検証" do
    it "ファクトリは有効" do
      expect(build(:web_push_subscription)).to be_valid
    end

    it "endpoint は必須" do
      expect(build(:web_push_subscription, endpoint: nil)).not_to be_valid
    end

    it "endpoint は https の URL だけを受け付ける" do
      expect(build(:web_push_subscription, endpoint: "http://fcm.googleapis.com/fcm/send/x")).not_to be_valid
      expect(build(:web_push_subscription, endpoint: "javascript:alert(1)")).not_to be_valid
      expect(build(:web_push_subscription, endpoint: push_endpoint)).to be_valid
    end

    it "既知の Push サービスのホストだけを受け付ける (任意の URL を叩かせない)" do
      expect(build(:web_push_subscription, endpoint: "https://example.com/push")).not_to be_valid
      expect(build(:web_push_subscription, endpoint: "https://127.0.0.1/push")).not_to be_valid
      expect(build(:web_push_subscription, endpoint: "https://fcm.googleapis.com.evil.test/x")).not_to be_valid
    end

    it "主要なブラウザの Push サービスは通る" do
      [
        "https://fcm.googleapis.com/fcm/send/abc",
        "https://updates.push.services.mozilla.com/wpush/v2/abc",
        "https://wns2-par02p.notify.windows.com/w/?token=abc",
        "https://web.push.apple.com/abc"
      ].each do |endpoint|
        expect(build(:web_push_subscription, endpoint: endpoint)).to be_valid, endpoint
      end
    end

    it "既定以外のポートは受け付けない" do
      expect(build(:web_push_subscription, endpoint: "https://fcm.googleapis.com:8443/fcm/send/x")).not_to be_valid
    end

    it "URI として読めない endpoint は例外ではなく検証エラーにする" do
      # URI::InvalidURIError のメッセージには endpoint 全文が入るので、配信まで持ち越さない
      subscription = build(:web_push_subscription, endpoint: "https://fcm.googleapis.com/^")

      expect { subscription.valid? }.not_to raise_error
      expect(subscription).not_to be_valid
    end

    it "非 ASCII の endpoint は受け付けない (btree の上限と URI の両方で壊れる)" do
      expect(build(:web_push_subscription, endpoint: "https://fcm.googleapis.com/#{"あ" * 10}"))
        .not_to be_valid
    end

    it "endpoint は長さで止める" do
      too_long = "https://fcm.googleapis.com/fcm/send/#{"a" * described_class::MAX_ENDPOINT_LENGTH}"

      expect(build(:web_push_subscription, endpoint: too_long)).not_to be_valid
    end

    it "endpoint は一意" do
      endpoint = push_endpoint("same")
      create(:web_push_subscription, endpoint: endpoint)

      expect(build(:web_push_subscription, endpoint: endpoint)).not_to be_valid
    end

    it "p256dh / auth は base64url の文字種だけを受け付ける" do
      expect(build(:web_push_subscription, p256dh_key: "not base64!")).not_to be_valid
      expect(build(:web_push_subscription, auth_key: "<script>")).not_to be_valid
    end

    it "p256dh は 65 バイトの非圧縮点でなければならない" do
      expect(build(:web_push_subscription, p256dh_key: Base64.urlsafe_encode64([ 4 ].pack("C") + "a" * 63)))
        .not_to be_valid
      expect(build(:web_push_subscription, p256dh_key: Base64.urlsafe_encode64([ 2 ].pack("C") + "a" * 64)))
        .not_to be_valid
      expect(build(:web_push_subscription, p256dh_key: push_p256dh)).to be_valid
    end

    it "auth は 16 バイトでなければならない" do
      expect(build(:web_push_subscription, auth_key: Base64.urlsafe_encode64("short"))).not_to be_valid
      expect(build(:web_push_subscription, auth_key: push_auth)).to be_valid
    end

    it "p256dh / auth は必須" do
      expect(build(:web_push_subscription, p256dh_key: nil)).not_to be_valid
      expect(build(:web_push_subscription, auth_key: "")).not_to be_valid
    end

    it "長すぎる user_agent は切り詰めて通す (購読を拒まない)" do
      subscription = build(:web_push_subscription, user_agent: "あ" * 400)

      expect(subscription).to be_valid
      expect(subscription.user_agent.length).to eq described_class::MAX_USER_AGENT_LENGTH
    end
  end

  describe ".upsert_for" do
    def upsert(owner, endpoint: push_endpoint("device-1"), p256dh: push_p256dh, auth: push_auth, user_agent: "Safari")
      described_class.upsert_for(user: owner, endpoint: endpoint, p256dh: p256dh, auth: auth, user_agent: user_agent)
    end

    it "初回は購読が作られる" do
      expect { upsert(user) }.to change(described_class, :count).by 1
    end

    it "同じ endpoint で 2 回購読しても行は 1 件のまま" do
      upsert(user)
      new_key = push_p256dh

      expect { upsert(user, p256dh: new_key) }.not_to change(described_class, :count)
      expect(described_class.sole.p256dh_key).to eq new_key
    end

    it "同じ端末で別の家族がログインしたら user を付け替える" do
      upsert(user)
      other = create(:user)

      expect { upsert(other) }.not_to change(described_class, :count)
      expect(described_class.sole.user).to eq other
    end

    it "購読し直すと失敗の記録はリセットされる" do
      subscription = upsert(user)
      subscription.record_failure!

      upsert(user)

      expect(subscription.reload.failure_count).to eq 0
    end

    it "別の端末なら行が増える" do
      upsert(user)

      expect { upsert(user, endpoint: push_endpoint("device-2")) }
        .to change(described_class, :count).by 1
    end

    it "壊れた入力は例外にせず、保存できていない購読を返す" do
      subscription = upsert(user, endpoint: "https://example.com/not-a-push-service")

      expect(subscription).not_to be_persisted
      expect(subscription.errors).to be_any
    end

    it "1 ユーザーの購読が上限を超えたら、古いものから消す" do
      over = described_class::MAX_PER_USER + 3
      over.times { |n| upsert(user, endpoint: push_endpoint("device-#{n}")) }

      expect(user.web_push_subscriptions.count).to eq described_class::MAX_PER_USER
      # 残るのは新しい方
      expect(user.web_push_subscriptions.pluck(:endpoint)).to include push_endpoint("device-#{over - 1}")
      expect(user.web_push_subscriptions.pluck(:endpoint)).not_to include push_endpoint("device-0")
    end

    it "上限の掃除で他人の購読は消さない" do
      other = create(:user)
      others = create_list(:web_push_subscription, 2, user: other)
      (described_class::MAX_PER_USER + 1).times { |n| upsert(user, endpoint: push_endpoint("mine-#{n}")) }

      expect(described_class.where(id: others.map(&:id)).count).to eq 2
    end

    it "一意制約の競合 (同時に 2 本) では掴み直して付け替える" do
      endpoint = push_endpoint("race")
      existing = create(:web_push_subscription, endpoint: endpoint)
      other = create(:user)
      # 検証をすり抜けて INSERT が走った状態を作る
      allow(described_class).to receive(:find_or_initialize_by).and_wrap_original do |original, *args|
        record = original.call(*args)
        allow(record).to receive(:save).and_raise(ActiveRecord::RecordNotUnique.new("duplicate key"))
        record
      end

      result = described_class.upsert_for(user: other, endpoint: endpoint,
        p256dh: push_p256dh, auth: push_auth)

      expect(result.id).to eq existing.id
      expect(existing.reload.user).to eq other
    end
  end

  describe "#record_delivery! / #record_failure!" do
    let(:subscription) { create(:web_push_subscription, user: user) }

    it "配信に成功すると最終配信が入り、失敗回数が 0 に戻る" do
      subscription.record_failure!

      freeze_time do
        subscription.record_delivery!

        expect(subscription.reload).to have_attributes(last_delivered_at: Time.current, failure_count: 0)
      end
    end

    it "失敗のたびに失敗回数が増える" do
      expect { 2.times { subscription.record_failure! } }
        .to change { subscription.reload.failure_count }.from(0).to 2
    end
  end

  describe "ユーザーとの関連" do
    it "ユーザーからたどれる" do
      subscription = create(:web_push_subscription, user: user)

      expect(user.web_push_subscriptions).to contain_exactly subscription
    end
  end
end
