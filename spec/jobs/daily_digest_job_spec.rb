require "rails_helper"

RSpec.describe DailyDigestJob, type: :job do
  include ActiveJob::TestHelper

  let!(:user) { create(:user, name: "おかあさん") }
  let!(:subscription) { create(:web_push_subscription, user: user) }

  before { configure_vapid }

  def perform
    described_class.perform_now
  end

  def digest_payload(body)
    {
      title: "つみくら",
      options: {
        body: body, icon: described_class::ICON, tag: described_class::TAG, data: { path: "/" }
      }
    }
  end

  # 在庫イベントが 1 件も無い auto の品目は q = 0 でペースも不明なので urgent になる
  # (docs/spec/02-forecast.md 7 節)
  def urgent_item(name)
    create(:item, name: name)
  end

  # 在庫が最低在庫数より多ければ ok (ペースが不明でも最低在庫数で判定できる)
  def ok_item(name)
    create(:item, name: name, minimum_quantity: 1).tap { create(:lot, item: _1, initial_quantity: 5) }
  end

  # 期限だけが悪い品目 (在庫は足りているので要購入は ok のまま)
  def expiring_item(name, expires_on: Date.current + 3)
    create(:item, :tracks_expiry, name: name, minimum_quantity: 1)
      .tap { create(:lot, item: _1, initial_quantity: 5, expires_on: expires_on) }
  end

  def record_state(item, purchase: "ok", expiry: "fresh")
    ItemAlertState.record!([ Notifications::Digest::Entry.new(
      item_id: item.id, name: item.name, purchase_status: purchase, expiry_status: expiry
    ) ])
  end

  describe "送るかどうか" do
    it "悪化した品目が 0 件なら何も送らない" do
      ok_item("せっけん")

      expect { perform }.not_to have_enqueued_job(WebPushDeliveryJob)
    end

    it "品目が 1 件も無くても落ちない" do
      expect { perform }.not_to raise_error
    end

    it "ok から urgent に悪化した品目があれば 1 通送る" do
      record_state(urgent_item("といれっとぺーぱー"), purchase: "ok")

      expect { perform }.to have_enqueued_job(WebPushDeliveryJob)
        .with(subscription.id, digest_payload("購入推奨 1 件 — といれっとぺーぱー")).once
    end

    it "初回 (状態が空) は既存の悪い品目がまとめて 1 通になる" do
      urgent_item("あぶらとりがみ")
      urgent_item("いんくかーとりっじ")
      urgent_item("うぇっとていっしゅ")

      expect { perform }.to have_enqueued_job(WebPushDeliveryJob).once
    end

    it "同じ日に 2 回走っても 2 通目は送られない (1 回目で状態が現在値になる)" do
      urgent_item("といれっとぺーぱー")

      expect { perform }.to have_enqueued_job(WebPushDeliveryJob).once

      clear_enqueued_jobs
      expect { perform }.not_to have_enqueued_job(WebPushDeliveryJob)
    end

    it "urgent -> ok -> urgent と戻ると再度送られる" do
      item = create(:item, name: "といれっとぺーぱー", minimum_quantity: 10)
      create(:lot, item: item, initial_quantity: 5) # 在庫 5 < 最低 10 で urgent

      expect { perform }.to have_enqueued_job(WebPushDeliveryJob).once

      item.update!(minimum_quantity: 1) # 在庫 5 > 最低 1 で ok に戻る
      clear_enqueued_jobs
      expect { perform }.not_to have_enqueued_job(WebPushDeliveryJob)

      item.update!(minimum_quantity: 10)
      clear_enqueued_jobs
      expect { perform }.to have_enqueued_job(WebPushDeliveryJob).once
    end

    it "期限が悪化した品目があれば送る" do
      expiring_item("ぎゅうにゅう")

      expect { perform }.to have_enqueued_job(WebPushDeliveryJob)
        .with(subscription.id, digest_payload("期限間近 1 件 — ぎゅうにゅう")).once
    end

    it "購入と期限の両方が悪化していても 1 通にまとめる" do
      urgent_item("といれっとぺーぱー")
      expiring_item("ぎゅうにゅう")

      expect { perform }.to have_enqueued_job(WebPushDeliveryJob)
        .with(subscription.id, digest_payload("購入推奨 1 件・期限間近 1 件 — といれっとぺーぱー ほか")).once
    end

    it "本文のラベルはステータスごと (soon を「購入推奨」と言わない)" do
      # 在庫が最低在庫数ちょうどなら soon (docs/spec/02-forecast.md 6 節)
      item = create(:item, name: "せっけん", minimum_quantity: 5)
      create(:lot, item: item, initial_quantity: 5)

      expect { perform }.to have_enqueued_job(WebPushDeliveryJob)
        .with(subscription.id, digest_payload("そろそろ購入 1 件 — せっけん")).once
    end

    it "期限切れは「期限切れ」と言う" do
      item = create(:item, :tracks_expiry, name: "ぎゅうにゅう", minimum_quantity: 1)
      create(:lot, item: item, initial_quantity: 5, expires_on: Date.current - 1)
      # 期限切れのロットは在庫 q から外れるので、要購入も urgent になる。
      # ここでは期限のラベルだけを見たいので、要購入は前回値を urgent にして横ばいにしておく
      record_state(item, purchase: "urgent", expiry: "fresh")

      expect { perform }.to have_enqueued_job(WebPushDeliveryJob)
        .with(subscription.id, digest_payload("期限切れ 1 件 — ぎゅうにゅう")).once
    end

    it "アーカイブ済みの品目は通知にも状態にも残さない" do
      archived = create(:item, :archived, name: "ふるいひんもく")
      record_state(archived, purchase: "ok")

      expect { perform }.not_to have_enqueued_job(WebPushDeliveryJob)
      expect(ItemAlertState.where(item_id: archived.id)).to be_empty
    end
  end

  describe "宛先" do
    before { record_state(urgent_item("といれっとぺーぱー"), purchase: "ok") }

    it "同じユーザーの端末が複数あれば端末ごとに 1 通ずつ送る" do
      create(:web_push_subscription, user: user)

      expect { perform }.to have_enqueued_job(WebPushDeliveryJob).exactly(2).times
    end

    it "無効化されたユーザーには送らない" do
      create(:web_push_subscription, user: create(:user, :deactivated))

      expect { perform }.to have_enqueued_job(WebPushDeliveryJob)
        .with(subscription.id, anything).exactly(1).times
    end

    it "購読が 1 件も無いユーザーには何も起きない" do
      create(:user)

      expect { perform }.to have_enqueued_job(WebPushDeliveryJob).exactly(1).times
    end

    it "鍵が未設定なら送らない" do
      unconfigure_vapid

      expect { perform }.not_to have_enqueued_job(WebPushDeliveryJob)
    end
  end

  describe "通知の種別" do
    it "notify_purchases が false のユーザーには要購入の悪化を送らない" do
      user.update!(notify_purchases: false)
      record_state(urgent_item("といれっとぺーぱー"), purchase: "ok")

      expect { perform }.not_to have_enqueued_job(WebPushDeliveryJob)
    end

    it "notify_purchases が false でも期限の悪化は届く" do
      user.update!(notify_purchases: false)
      expiring_item("ぎゅうにゅう")

      expect { perform }.to have_enqueued_job(WebPushDeliveryJob)
        .with(subscription.id, digest_payload("期限間近 1 件 — ぎゅうにゅう")).once
    end

    it "notify_expiries が false のユーザーには期限の悪化を送らない" do
      user.update!(notify_expiries: false)
      expiring_item("ぎゅうにゅう")

      expect { perform }.not_to have_enqueued_job(WebPushDeliveryJob)
    end

    it "notify_expiries が false でも要購入の悪化は届く" do
      user.update!(notify_expiries: false)
      urgent_item("といれっとぺーぱー")
      expiring_item("ぎゅうにゅう")

      expect { perform }.to have_enqueued_job(WebPushDeliveryJob)
        .with(subscription.id, digest_payload("購入推奨 1 件 — といれっとぺーぱー")).once
    end

    it "両方 OFF のユーザーには送らない" do
      user.update!(notify_purchases: false, notify_expiries: false)
      urgent_item("といれっとぺーぱー")
      expiring_item("ぎゅうにゅう")

      expect { perform }.not_to have_enqueued_job(WebPushDeliveryJob)
    end
  end

  describe "見送り中 (スヌーズ) の品目" do
    it "見送り中の品目は要購入の通知から除く" do
      item = urgent_item("といれっとぺーぱー")
      create(:shopping_list_item, :snoozed, item: item, added_by: user)

      expect { perform }.not_to have_enqueued_job(WebPushDeliveryJob)
    end

    it "見送りが当日までなら、まだ見送り中として扱う" do
      item = urgent_item("といれっとぺーぱー")
      create(:shopping_list_item, item: item, added_by: user, snoozed_until: Date.current, added_manually: true)

      expect { perform }.not_to have_enqueued_job(WebPushDeliveryJob)
    end

    it "見送り中に悪化した品目は、見送りが切れた翌朝に通知される" do
      item = urgent_item("といれっとぺーぱー")
      snooze = create(:shopping_list_item, :snoozed, item: item, added_by: user)

      expect { perform }.not_to have_enqueued_job(WebPushDeliveryJob)

      # 見送りが切れた翌朝 (purge_stale! がこの行を消す)
      snooze.update!(snoozed_until: Date.current - 1)
      clear_enqueued_jobs

      expect { perform }.to have_enqueued_job(WebPushDeliveryJob)
        .with(subscription.id, digest_payload("購入推奨 1 件 — といれっとぺーぱー")).once
    end

    it "見送りが切れていれば通知する" do
      item = urgent_item("といれっとぺーぱー")
      create(:shopping_list_item, item: item, added_by: user, snoozed_until: Date.current - 1)

      expect { perform }.to have_enqueued_job(WebPushDeliveryJob).once
    end

    it "見送り中でも期限の悪化は届く" do
      item = expiring_item("ぎゅうにゅう")
      create(:shopping_list_item, :snoozed, item: item, added_by: user)

      expect { perform }.to have_enqueued_job(WebPushDeliveryJob)
        .with(subscription.id, digest_payload("期限間近 1 件 — ぎゅうにゅう")).once
    end
  end

  describe "item_alert_states の更新" do
    it "送信後に現在値で更新される" do
      urgent = urgent_item("といれっとぺーぱー")
      expiring = expiring_item("ぎゅうにゅう")

      perform

      expect(ItemAlertState.find_by(item_id: urgent.id))
        .to have_attributes(notified_purchase_status: "urgent", notified_expiry_status: "fresh")
      expect(ItemAlertState.find_by(item_id: expiring.id))
        .to have_attributes(notified_purchase_status: "ok", notified_expiry_status: "expiring_soon")
    end

    it "改善した品目も現在値で記録する (回復後の再悪化で鳴らすため)" do
      item = ok_item("せっけん")
      record_state(item, purchase: "urgent")

      perform

      expect(ItemAlertState.find_by(item_id: item.id).notified_purchase_status).to eq "ok"
    end

    it "送らなかった日 (悪化 0 件) でも更新する" do
      item = ok_item("せっけん")

      expect { perform }.to change { ItemAlertState.exists?(item_id: item.id) }.from(false).to true
    end

    it "見送り中の品目の要購入ステータスは前回値のまま据え置く" do
      # 現在値 (urgent) で記録すると、見送りが切れたあとも「横ばい」になって二度と通知されない
      item = urgent_item("といれっとぺーぱー")
      record_state(item, purchase: "ok")
      create(:shopping_list_item, :snoozed, item: item, added_by: user)

      perform

      expect(ItemAlertState.find_by(item_id: item.id).notified_purchase_status).to eq "ok"
    end

    it "見送り中でも期限のステータスは現在値で記録する" do
      item = expiring_item("ぎゅうにゅう")
      create(:shopping_list_item, :snoozed, item: item, added_by: user)

      perform

      expect(ItemAlertState.find_by(item_id: item.id).notified_expiry_status).to eq "expiring_soon"
    end

    it "鍵が未設定で送れなかった日でも更新する" do
      unconfigure_vapid
      item = urgent_item("といれっとぺーぱー")

      perform

      expect(ItemAlertState.find_by(item_id: item.id).notified_purchase_status).to eq "urgent"
    end
  end

  describe "基準日と掃除" do
    it "BatchForecaster と Expiry::Evaluator に同じ today を渡す" do
      allow(Forecast::BatchForecaster).to receive(:call).and_call_original
      allow(Expiry::Evaluator).to receive(:call).and_call_original

      perform

      expect(Forecast::BatchForecaster).to have_received(:call).with(anything, today: Date.current).once
      expect(Expiry::Evaluator).to have_received(:call).with(anything, today: Date.current).once
    end

    it "買い物リストの古い行を掃除する" do
      item = ok_item("せっけん")
      stale = create(:shopping_list_item, item: item, added_by: user, snoozed_until: Date.current - 1)

      expect { perform }.to change { ShoppingListItem.exists?(stale.id) }.from(true).to false
    end

    it "チェック済みの行は掃除しない" do
      item = ok_item("せっけん")
      checked = create(:shopping_list_item, :checked, item: item, added_by: user)

      expect { perform }.not_to change { ShoppingListItem.exists?(checked.id) }
    end
  end
end
