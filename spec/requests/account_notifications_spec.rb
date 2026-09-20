require "rails_helper"

# JS が要る部分 (許可ダイアログ・購読) はヘッドレスでは確かめられないので、
# **Stimulus が掴むターゲットとデータ属性がビューに出ていること**をここで固定する。
# 実機での確認手順は docs/spec/04-notifications.md 6 節。
RSpec.describe "アカウント設定の通知セクション", type: :request do
  let(:user) { create(:user) }

  before { sign_in user }

  describe "GET /account (鍵が設定されている)" do
    before { configure_vapid }

    def notification_section
      response.parsed_body.css(%([data-controller="push-subscription"])).first
    end

    it "購読の controller と登録先の URL を出す" do
      get account_path

      expect(notification_section).to be_present
      expect(notification_section["data-push-subscription-url-value"]).to eq web_push_subscriptions_path
    end

    it "VAPID の公開鍵をここに出す (レイアウトの meta には置かない)" do
      get account_path

      expect(notification_section["data-push-subscription-public-key-value"])
        .to eq VapidHelper::VAPID_KEYS.fetch(:public_key)
      expect(response.parsed_body.css(%(meta[name="vapid-public-key"]))).to be_empty
    end

    it "Stimulus のターゲットがそろっている" do
      get account_path

      targets = notification_section.css("[data-push-subscription-target]")
        .map { _1["data-push-subscription-target"] }

      expect(targets).to include "status", "subscribe", "unsubscribe", "unsupported", "ios"
    end

    it "購読のボタンは JS が出すまで隠しておく (JS 無しでは押せない)" do
      get account_path

      subscribe_button = notification_section.css(%([data-push-subscription-target="subscribe"])).first
      expect(subscribe_button.attributes).to have_key "hidden"
    end

    it "iOS 向けの案内を持っている" do
      get account_path

      ios = notification_section.css(%([data-push-subscription-target="ios"])).first
      expect(ios.text).to include "ホーム画面に追加"
    end

    it "テスト送信のボタンを出す" do
      get account_path

      expect(response.parsed_body.css(%(form[action="#{notification_test_path}"]))).to be_any
    end
  end

  describe "GET /account (鍵が未設定)" do
    before { unconfigure_vapid }

    it "鍵が無いことを知らせる" do
      get account_path

      expect(response.parsed_body.css("[data-vapid-missing]").text).to include "鍵"
    end

    it "購読のボタンもテスト送信も出さない" do
      get account_path

      expect(response.parsed_body.css(%([data-controller="push-subscription"]))).to be_empty
      expect(response.parsed_body.css(%(form[action="#{notification_test_path}"]))).to be_empty
    end

    it "種別の ON/OFF は鍵が無くても設定できる" do
      get account_path

      expect(response.parsed_body.css(%(form[action="#{account_notification_setting_path}"]))).to be_any
    end
  end

  describe "登録済みの端末" do
    it "ブラウザの要約と最終配信を出す" do
      create(:web_push_subscription, :delivered, user: user,
        user_agent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 " \
                    "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1")

      get account_path

      expect(rendered_list("通知を受け取る端末")).to include "iPhone / Safari"
      expect(rendered_list("通知を受け取る端末")).to include "最終配信"
    end

    it "まだ配信していない端末はそう書く" do
      create(:web_push_subscription, user: user)

      get account_path

      expect(rendered_list("通知を受け取る端末")).to include "まだ配信していません"
    end

    it "endpoint は画面に出さない (端末を特定できる値のため)" do
      subscription = create(:web_push_subscription, user: user)

      get account_path

      expect(response.body).not_to include subscription.endpoint
    end

    it "他人の端末は出さない" do
      create(:web_push_subscription, user: create(:user), user_agent: "よそのブラウザ")

      get account_path

      expect(response.body).not_to include "よそのブラウザ"
    end

    it "削除のボタンを出す" do
      subscription = create(:web_push_subscription, user: user)

      get account_path

      expect(response.parsed_body.css(%(form[action="#{web_push_subscription_path(subscription)}"]))).to be_any
    end
  end

  describe "PATCH /account/notification_setting" do
    it "購入のお知らせを止められる" do
      patch account_notification_setting_path,
        params: { user: { notify_purchases: "0", notify_expiries: "1" } }

      expect(user.reload).to have_attributes(notify_purchases: false, notify_expiries: true)
      expect(response).to redirect_to account_path
    end

    it "期限のお知らせを止められる" do
      patch account_notification_setting_path,
        params: { user: { notify_purchases: "1", notify_expiries: "0" } }

      expect(user.reload).to have_attributes(notify_purchases: true, notify_expiries: false)
    end

    it "止めたものを戻せる" do
      user.update!(notify_purchases: false)

      patch account_notification_setting_path,
        params: { user: { notify_purchases: "1", notify_expiries: "1" } }

      expect(user.reload.notify_purchases).to be true
    end

    it "役割や無効化はここからは変えられない" do
      patch account_notification_setting_path,
        params: { user: { notify_purchases: "1", role: "admin", deactivated_at: Time.current } }

      expect(user.reload).to have_attributes(role: "member", deactivated_at: nil)
    end
  end
end
