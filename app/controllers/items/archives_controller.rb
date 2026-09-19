module Items
  # 品目は物理削除しない (docs/spec/01-domain-model.md 3 節)。
  # archived_at を ItemsController#update で permit しないために分ける
  class ArchivesController < ApplicationController
    before_action :set_item

    def create
      @item.archive!
      redirect_to @item, notice: "「#{@item.name}」をアーカイブしました。一覧には出なくなります。"
    end

    def destroy
      @item.restore!
      redirect_to @item, notice: "「#{@item.name}」のアーカイブを解除しました。", status: :see_other
    end

    private
      def set_item
        @item = Item.find(params[:item_id])
      end
  end
end
