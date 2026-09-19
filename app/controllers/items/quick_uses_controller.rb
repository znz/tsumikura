module Items
  # ワンタップ使用 (docs/spec/03-screens.md 画面 4b)。
  # 数量 1・今日・FEFO 自動・用途なしで即記録し、「取り消し」付きのトーストを出す。
  # 確認ダイアログは出さない代わりに、取り消せることで安心して押せるようにする。
  #
  # JS が無くても動く: Turbo Stream を受け取れないときは、元の画面に戻して
  # フラッシュのトースト (取り消しボタン付き) を出す。
  class QuickUsesController < ApplicationController
    include ItemDetails

    def create
      @item = Item.find(params[:item_id])
      @usage_record = Stock::RecordUsage.call(item: @item, user: Current.user,
        attributes: { quantity: 1, used_on: Date.current })
      @undo_usage_record_id = @usage_record.id if @usage_record.persisted?
      @toast_message = toast_message

      respond_to do |format|
        # 在庫・ロット・最近の記録をまとめて描き直す (Turbo は無い id を黙って無視するので、
        # 品目一覧からでも品目詳細からでも同じ応答で足りる)。
        # リダイレクトで済む JS 無しの経路では読まない
        format.turbo_stream { load_item_detail(@item) }
        format.html { redirect_to_previous_screen }
      end
    end

    private
      # 在庫記録が足りなくても記録は成功させる (設計原則 3)。
      # 黙って在庫を作ると気づけないので、補填したことは必ず伝える
      def toast_message
        return @usage_record.errors.full_messages.to_sentence unless @usage_record.persisted?

        message = "「#{@item.name}」を 1 #{@item.unit} 使いました。"
        compensated = @usage_record.compensated_quantity.to_i
        return message unless compensated.positive?

        "#{message}在庫記録が不足していたため #{compensated} #{@item.unit} を調整しました。"
      end

      # 一覧から押したら一覧に、詳細から押したら詳細に戻る。
      # 外部サイトからの Referer は無視して品目詳細に倒す (allow_other_host: false)
      def redirect_to_previous_screen
        flash[:toast] = @toast_message
        flash[:undo_usage_record_id] = @undo_usage_record_id if @undo_usage_record_id
        redirect_back_or_to item_path(@item), status: :see_other, allow_other_host: false
      end
  end
end
