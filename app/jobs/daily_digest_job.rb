# 日次ダイジェスト (docs/spec/04-notifications.md 4 節)。config/recurring.yml から朝 8 時 JST に走る。
#
# **前回突き合わせたときよりステータスが悪化した品目があるときだけ、1 日 1 通**送る。
# 即時通知はしない。悪化が 0 件なら黙って終わる (同じ日に 2 回走っても 2 通目は送られない
# = 1 回目で item_alert_states が現在値に更新されるため)。
class DailyDigestJob < ApplicationJob
  queue_as :default

  # 手で流したぶんと定時実行が重なっても、同じ朝に 2 通は送らせない
  # (state の更新で冪等ではあるが、2 本が同時に走ると両方が「悪化」を見てしまう)
  limits_concurrency key: "daily_digest"

  TITLE = "つみくら".freeze
  # 通知をタップしたときに開く画面 (ダッシュボード)。service-worker.js が data.path を開く
  PATH = "/".freeze
  # 同じ日に 2 通目が来たら前のものを置き換える (通知欄に積み上げない)
  TAG = "daily-digest".freeze
  # 通知の枠に対して 512px は大きすぎるので 192px を使う (service-worker.js の既定と同じ)
  ICON = "/icon-192.png".freeze

  def perform
    # 日付をまたぐ瞬間に走っても 1 回のダイジェストの中で基準日がずれないように 1 度だけ取る
    # (docs/spec/02-forecast.md 14 節)
    today = Date.current

    # 買い物リストの古い永続行の掃除 (Phase 11 からの申し送り)。
    # 「1 日 1 回でよい掃除」なので、ジョブを増やさずにダイジェストと同じ日次の入口で呼ぶ
    ShoppingListItem.purge_stale!(today)

    items = Item.active.ordered.to_a
    entries = entries_for(items, today)
    previous = previous_states(items)

    deliver(Notifications::Digest.call(entries: entries, previous: previous))

    # **送信の成否にかかわらず**更新する。改善も記録するので、回復した品目がもう一度
    # 悪化したらまた通知される。見送り中の品目の要購入だけは前回値のまま据え置く
    # (Notifications::Digest.states)
    ItemAlertState.record!(Notifications::Digest.states(entries: entries, previous: previous))
    ItemAlertState.purge_archived!
  end

  private
    def entries_for(items, today)
      forecasts = Forecast::BatchForecaster.call(items, today: today)
      expiries = Expiry::Evaluator.call(items, today: today)
      snoozed = snoozed_item_ids(today)

      # どちらもアーカイブ済みを落とすので、結果に無い品目はそのまま飛ばす
      items.filter_map do |item|
        forecast = forecasts[item.id]
        expiry = expiries[item.id]
        next if forecast.nil? || expiry.nil?

        Notifications::Digest::Entry.new(
          item_id: item.id,
          name: item.name,
          purchase_status: forecast.status,
          expiry_status: expiry.status,
          snoozed: snoozed.include?(item.id)
        )
      end
    end

    # 「今回は買わない」で見送り中の品目。境界は買い物リストと同じ (snoozed_until >= today)
    def snoozed_item_ids(today)
      ShoppingListItem.for_items.where(snoozed_until: today..).pluck(:item_id).to_set
    end

    def previous_states(items)
      ItemAlertState.where(item_id: items.map(&:id)).to_h do |state|
        [ state.item_id, Notifications::Digest::Previous.new(
          purchase_status: state.notified_purchase_status,
          expiry_status: state.notified_expiry_status
        ) ]
      end
    end

    # 有効なユーザーのうち、その人の種別 ON/OFF で 1 件以上残る人の全購読に 1 通ずつ。
    # 無効化されたユーザー (deactivated_at) には送らない
    def deliver(summary)
      return if summary.empty?
      return unless Vapid.configured?

      # 通知の文言は画面と同じ語彙を使う (docs/spec/02-forecast.md 14 節)。
      # soon をまとめて「購入推奨」と言わないよう、ステータスごとにラベルを引く
      purchase_labels = Notifications::Digest::PURCHASE_ALERTS.index_with { I18n.t("forecast.status.#{_1}") }
      expiry_labels = Notifications::Digest::EXPIRY_ALERTS.index_with { I18n.t("expiry.status.#{_1}") }

      User.active.includes(:web_push_subscriptions).find_each do |user|
        personal = summary.only(purchases: user.notify_purchases?, expiries: user.notify_expiries?)
        next if personal.empty?

        payload = {
          title: TITLE,
          options: {
            body: personal.body(purchase_labels: purchase_labels, expiry_labels: expiry_labels),
            icon: ICON,
            tag: TAG,
            data: { path: PATH }
          }
        }
        user.web_push_subscriptions.each { WebPushDeliveryJob.perform_later(_1.id, payload) }
      end
    end
end
