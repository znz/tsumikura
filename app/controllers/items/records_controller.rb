module Items
  # 品目の記録の全履歴 (docs/spec/03-screens.md 画面 3b)。
  # 品目詳細の「最近の記録」は 10 件で切るので、その続きを見るための画面。
  # 記録の集約は品目詳細と共有する (Stock::RecordHistory) ので、
  # 「詳細には出ているのに履歴に無い」という食い違いは起きない。
  class RecordsController < ApplicationController
    before_action :set_item

    # 家庭用なので 1 品目の記録は多くても数千件。ページネーションは置かず全件を 1 ページに出す
    # (ページを送るより、ブラウザの検索で探せるほうが速い)
    def index
      @records = Stock::RecordHistory.call(@item)
    end

    private
      # 品目詳細と同じ扱い。アーカイブしても記録は残るので、アーカイブ済みでも履歴は見られる
      def set_item
        @item = Item.find_by_param!(params[:item_id])
      end
  end
end
