# 通知のテスト送信 (docs/spec/03-screens.md 画面 11)。
#
# **自分の購読にだけ**送る (家族の端末を鳴らさない)。
# 実機でしか確かめられない配線 (鍵・service worker・購読) を 1 タップで確かめるためのもの。
class NotificationTestsController < ApplicationController
  # 押すたびに Push サービスへ POST が飛ぶので、連打で外部サービスを叩かせない
  rate_limit to: 5, within: 1.minute, only: :create,
    with: -> { redirect_to account_path, alert: "テスト送信は少し時間をおいてからやり直してください。" }

  TITLE = "つみくら".freeze
  BODY = "テスト送信です。通知はこのように届きます。".freeze
  # 日次ダイジェストの通知を置き換えないよう、別の tag にする
  TAG = "notification-test".freeze
  # 通知の枠に対して 512px は大きすぎるので 192px を使う (service-worker.js の既定と同じ)
  ICON = "/icon-192.png".freeze

  def create
    return redirect_to account_path, alert: "サーバに通知の鍵が設定されていません。" unless Vapid.configured?

    subscriptions = Current.user.web_push_subscriptions.to_a

    if subscriptions.empty?
      redirect_to account_path, alert: "通知を受け取る端末がまだ登録されていません。"
    else
      subscriptions.each { WebPushDeliveryJob.perform_later(_1.id, payload) }
      redirect_to account_path, notice: "テスト送信しました (#{subscriptions.size} 台)。"
    end
  end

  private
    def payload
      { title: TITLE, options: { body: BODY, icon: ICON, tag: TAG, data: { path: account_path } } }
    end
end
