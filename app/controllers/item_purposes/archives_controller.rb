module ItemPurposes
  # 使用記録が紐づく用途は削除できない (履歴が消えるため) ので、アーカイブで一覧から外す。
  # archived_at を ItemPurposesController#update で permit しないために分ける
  class ArchivesController < ApplicationController
    before_action :set_purpose

    def create
      @purpose.archive!
      redirect_to item_purposes_path(@item), status: :see_other,
        notice: "用途「#{@purpose.name}」をアーカイブしました。使用記録は残ります。"
    end

    def destroy
      @purpose.restore!
      redirect_to item_purposes_path(@item), status: :see_other,
        notice: "用途「#{@purpose.name}」のアーカイブを解除しました。"
    end

    private
      def set_purpose
        @item = Item.find(params[:item_id])
        @purpose = @item.item_purposes.find(params[:purpose_id])
      end
  end
end
