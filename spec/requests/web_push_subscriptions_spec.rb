require "rails_helper"

RSpec.describe "通知の購読", type: :request do
  let(:user) { create(:user) }
  let(:endpoint) { push_endpoint("abc") }

  before { sign_in user }

  def subscribe(attributes = {})
    post web_push_subscriptions_path,
      params: { web_push_subscription: {
        endpoint: endpoint, p256dh: push_p256dh, auth: push_auth
      }.merge(attributes) },
      as: :json
  end

  describe "POST /web_push_subscriptions" do
    it "購読を登録すると WebPushSubscription が作られる" do
      expect { subscribe }.to change(WebPushSubscription, :count).by 1

      expect(WebPushSubscription.sole).to have_attributes(user: user, endpoint: endpoint)
    end

    # JS はこの値をそのまま URL に入れるので Base58 の 22 文字で返す
    it "作った購読の id を Base58 で返す (JS が「オフ」の URL に使う)" do
      subscribe

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["id"]).to eq WebPushSubscription.sole.to_param
    end

    it "ブラウザを user_agent に残す" do
      post web_push_subscriptions_path,
        params: { web_push_subscription: { endpoint: endpoint, p256dh: push_p256dh, auth: push_auth } },
        headers: { "User-Agent" => "テスト用ブラウザ" }, as: :json

      expect(WebPushSubscription.sole.user_agent).to eq "テスト用ブラウザ"
    end

    it "同じ endpoint で 2 回購読しても行は 1 件のまま" do
      subscribe
      new_key = push_p256dh

      expect { subscribe(p256dh: new_key) }.not_to change(WebPushSubscription, :count)
      expect(WebPushSubscription.sole.p256dh_key).to eq new_key
    end

    it "同じ端末で別の家族がログインしたら購読を付け替える" do
      other = create(:user)
      create(:web_push_subscription, user: other, endpoint: endpoint)

      expect { subscribe }.not_to change(WebPushSubscription, :count)
      expect(WebPushSubscription.sole.user).to eq user
    end

    it "https 以外の endpoint は 422 で断る (500 にしない)" do
      expect { subscribe(endpoint: "http://fcm.googleapis.com/fcm/send/x") }
        .not_to change(WebPushSubscription, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"]).to be_any
    end

    it "既知の Push サービス以外の endpoint は 422 で断る" do
      expect { subscribe(endpoint: "https://internal.example.com/push") }
        .not_to change(WebPushSubscription, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "鍵の形式が違えば 422 で断る" do
      subscribe(p256dh: "<script>alert(1)</script>")

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "鍵の長さが違えば 422 で断る (配信時の OpenSSL の例外を先に潰す)" do
      subscribe(auth: Base64.urlsafe_encode64("short"))

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "連打を防ぐため rate_limit が掛かっている" do
      keys = rate_limit_keys { subscribe }

      expect(keys).to include(a_string_matching(%r{\Arate-limit:web_push_subscriptions}))
    end

    it "endpoint が空なら 422 で断る" do
      subscribe(endpoint: "")

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "パラメータが丸ごと無ければ 400 で断る (500 にしない)" do
      post web_push_subscriptions_path, params: {}, as: :json

      expect(response).to have_http_status(:bad_request)
    end

    it "user_id や failure_count はフォームから変更できない" do
      other = create(:user)

      subscribe(user_id: other.id, failure_count: 99, last_delivered_at: Time.current)

      expect(WebPushSubscription.sole).to have_attributes(user: user, failure_count: 0, last_delivered_at: nil)
    end
  end

  describe "DELETE /web_push_subscriptions/:id" do
    it "自分の購読を削除できる" do
      subscription = create(:web_push_subscription, user: user)

      expect { delete web_push_subscription_path(subscription) }
        .to change(WebPushSubscription, :count).by(-1)

      expect(response).to redirect_to account_path
    end

    it "他人の購読は消せない" do
      subscription = create(:web_push_subscription, user: create(:user))

      expect { delete web_push_subscription_path(subscription) }
        .not_to change(WebPushSubscription, :count)
    end

    it "他人の購読を消そうとしても 404 を見せない (古い画面からの操作)" do
      subscription = create(:web_push_subscription, user: create(:user))

      delete web_push_subscription_path(subscription)

      expect(response).to redirect_to account_path
    end

    it "既に消えている購読への操作でも 404 にしない" do
      subscription = create(:web_push_subscription, user: user)
      subscription.destroy!

      delete web_push_subscription_path(subscription)

      expect(response).to redirect_to account_path
    end

    it "JSON では 204 を返す (JS からの解除)" do
      subscription = create(:web_push_subscription, user: user)

      delete web_push_subscription_path(subscription), as: :json

      expect(response).to have_http_status(:no_content)
      expect(WebPushSubscription.exists?(subscription.id)).to be false
    end
  end
end
