# 端末ごとの Web Push の購読 (docs/spec/04-notifications.md 3 節)。
#
# create はブラウザの PushSubscription を JSON で受け取る (push_subscription_controller.js)。
# endpoint をキーにした upsert なので、同じ端末から何度呼ばれても行は 1 件のままになる。
class WebPushSubscriptionsController < ApplicationController
  # 購読の登録は画面を開くたびに 1 回しか走らないので、これを超えるのは異常。
  # 上限 20 件の掃除と合わせて、行を作り続けられないようにする
  rate_limit to: 20, within: 1.minute, only: :create,
    with: -> { head :too_many_requests }

  def create
    subscription = WebPushSubscription.upsert_for(
      user: Current.user,
      endpoint: subscription_params[:endpoint],
      p256dh: subscription_params[:p256dh],
      auth: subscription_params[:auth],
      user_agent: request.user_agent
    )

    if subscription.persisted? && subscription.errors.empty?
      # JS は id を覚えて「通知をオフ」の URL に使う (画面には endpoint を出さない)。
      # URL に入れる値なので Base58 の 22 文字で返す (docs/spec/03-screens.md)
      render json: { id: subscription.to_param }, status: :created
    else
      render json: { errors: subscription.errors.full_messages }, status: :unprocessable_content
    end
  end

  def destroy
    # 他人の購読は消せない (id は Current.user のぶんだけを引く)。
    # 既に消えている購読への操作 (古い画面・端末側で解除済み) は 404 にせず成功として扱う
    Current.user.web_push_subscriptions.find_by_param(params[:id])&.destroy

    respond_to do |format|
      format.json { head :no_content }
      format.html { redirect_to account_path, notice: "この端末の通知を解除しました。" }
    end
  end

  private
    # user_id / failure_count / last_delivered_at はフォームからは変更できない
    def subscription_params
      @subscription_params ||= params.expect(web_push_subscription: [ :endpoint, :p256dh, :auth ])
    end
end
