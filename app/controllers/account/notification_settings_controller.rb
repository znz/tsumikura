module Account
  # 通知の種別 ON/OFF (docs/spec/04-notifications.md 4 節)。
  #
  # 端末の購読 (WebPushSubscriptionsController) とは別の軸で、
  # 「何を知らせてほしいか」をユーザーごとに持つ。JS 無しで動くふつうのフォーム。
  class NotificationSettingsController < ApplicationController
    def update
      # 役割・無効化・表示名は別の口で更新する (ここでは通知の 2 列だけ permit する)
      if Current.user.update(params.expect(user: [ :notify_purchases, :notify_expiries ]))
        redirect_to account_path, notice: "通知の設定を更新しました。"
      else
        redirect_to account_path, alert: Current.user.errors.full_messages.to_sentence
      end
    end
  end
end
