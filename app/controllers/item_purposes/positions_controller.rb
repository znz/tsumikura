module ItemPurposes
  # 並べ替え (上へ / 下へ)。position を ItemPurposesController#update で permit しないために分ける。
  # 並べ替えは品目の中だけで閉じる (ItemPurpose#positioned_siblings)
  class PositionsController < ApplicationController
    def update
      item = Item.find(params[:item_id])
      purpose = item.item_purposes.find(params[:purpose_id])
      # 端まで来ている / 方向が不正なときは move! が false を返す。
      # 並べ替えは失敗しても困らないので、どちらでも一覧に戻る
      purpose.move!(params[:direction])

      redirect_to item_purposes_path(item), status: :see_other
    end
  end
end
