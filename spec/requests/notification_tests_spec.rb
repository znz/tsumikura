require "rails_helper"

RSpec.describe "通知のテスト送信", type: :request do
  include ActiveJob::TestHelper

  let(:user) { create(:user) }

  before do
    configure_vapid
    sign_in user
  end

  describe "POST /notification_test" do
    it "自分の購読にだけ送る" do
      mine = create(:web_push_subscription, user: user)
      create(:web_push_subscription, user: create(:user))

      expect { post notification_test_path }
        .to have_enqueued_job(WebPushDeliveryJob).with(mine.id, anything).exactly(1).times
    end

    it "自分の端末が複数あれば端末ごとに送る" do
      create_list(:web_push_subscription, 2, user: user)

      expect { post notification_test_path }
        .to have_enqueued_job(WebPushDeliveryJob).exactly(2).times
    end

    it "送ったら画面に戻って知らせる" do
      create(:web_push_subscription, user: user)

      post notification_test_path

      expect(response).to redirect_to account_path
      expect(flash[:notice]).to be_present
    end

    it "端末が登録されていなければ何も送らず案内する" do
      expect { post notification_test_path }.not_to have_enqueued_job(WebPushDeliveryJob)

      expect(response).to redirect_to account_path
      expect(flash[:alert]).to be_present
    end

    it "連打を防ぐため rate_limit が掛かっている" do
      keys = rate_limit_keys { post notification_test_path }

      expect(keys).to include(a_string_matching(%r{\Arate-limit:notification_tests}))
    end

    it "鍵が未設定なら何も送らず案内する" do
      unconfigure_vapid
      create(:web_push_subscription, user: user)

      expect { post notification_test_path }.not_to have_enqueued_job(WebPushDeliveryJob)

      expect(flash[:alert]).to include "鍵"
    end
  end
end
