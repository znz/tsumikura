module StockTakes
  # 棚卸の確定 (docs/spec/03-screens.md 画面 6 の (5))。
  # finalized_at を StockTakesController#update で permit しないために分ける。
  # 在庫を動かすのはここだけで、実際の処理は Stock::FinalizeStockTake が
  # 1 トランザクション・品目の id 昇順のロックで行う。
  class FinalizationsController < ApplicationController
    def create
      # すでに確定済みなら 404 (確定済みの棚卸は編集できない)。
      # 2 台で同時に押された場合はロックの後の AlreadyFinalized で拾う
      stock_take = StockTake.drafts.find_by_param!(params[:stock_take_id])

      Stock::FinalizeStockTake.call(stock_take, user: Current.user)

      redirect_to stock_take_path(stock_take), notice: finalized_notice(stock_take)
    rescue Stock::FinalizeStockTake::AlreadyFinalized
      redirect_to stock_take_path(params[:stock_take_id]), status: :see_other,
        alert: "この棚卸はすでに確定しています。"
    rescue Stock::FinalizeStockTake::NothingCounted
      redirect_to stock_take_path(params[:stock_take_id]), status: :see_other,
        alert: "まだ 1 件も数えていないので確定できません。"
    rescue Stock::FinalizeStockTake::LedgerInconsistent => e
      redirect_to stock_take_path(params[:stock_take_id]), status: :see_other,
        alert: "在庫記録に食い違いがあるため確定できませんでした。#{e.message}"
    end

    private
      def finalized_notice(stock_take)
        increased = stock_take.increased_entries.count
        decreased = stock_take.decreased_entries.count

        "棚卸を確定しました (増 #{increased} 件 / 減 #{decreased} 件)。"
      end
  end
end
