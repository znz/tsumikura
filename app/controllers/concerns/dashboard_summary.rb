# ダッシュボードの集計 (docs/spec/03-screens.md 画面 1)。
#
# DashboardsController#show と、ダッシュボードから押されたワンタップ使用の Turbo Stream 応答
# (Items::QuickUsesController) が同じ描画を共有するためにここにまとめる。
# アラートカードの件数とタイルのバッジが同じ判定から出ていないと、
# 「タイルは購入推奨なのにカードは 0 件」という食い違いがリロードまで残る。
module DashboardSummary
  extend ActiveSupport::Concern

  # クイック使用のタイルに出す品目の数 (お気に入り → 最近使った順)
  QUICK_USE_LIMIT = 8
  # 「最近の記録」に出す件数 (全品目横断)
  RECENT_RECORDS_LIMIT = 5

  private
    # アーカイブ済みの品目はどこにも出さない (docs/spec/02-forecast.md 9 節)。
    # today は呼び出し側で 1 回だけ取ったものを渡す (0 時をまたいでずれないように)
    def load_dashboard_summary(today = Date.current)
      @today = today
      @items = Item.active.ordered.to_a
      @forecasts = Forecast::BatchForecaster.call(@items, today: today)
      @expiries = Expiry::Evaluator.call(@items, today: today)
      @alert_counts = alert_counts
      @quick_use_items = quick_use_items
      # 品目詳細の @recent_records (ItemDetails) と衝突しないよう別の名前にする
      # (ワンタップ使用の応答では両方を同時に持つ)
      @dashboard_recent_records = dashboard_recent_records
    end

    # unknown (データ不足) は要購入に数えない (docs/spec/02-forecast.md 1 節)。
    # status が :urgent / :soon のものだけを数えるので、自然に外れる
    def alert_counts
      purchase = @items.map { |item| @forecasts[item.id]&.status }
      expiry = @items.map { |item| @expiries[item.id]&.status }

      {
        urgent: purchase.count(:urgent),
        soon: purchase.count(:soon),
        expired: expiry.count(:expired),
        expiring_soon: expiry.count(:expiring_soon)
      }
    end

    # お気に入り (よみ順) が先、続いて最近使った順。同じ品目は 1 回だけ出す。
    # 読み込み済みの @items から選ぶのでクエリは増えない
    def quick_use_items
      favorites = @items.select(&:favorite?)
      recently_used = @items.reject { |item| item.last_consumed_on.nil? }
        .sort_by { |item| [ item.last_consumed_on, item.id ] }.reverse

      (favorites + recently_used).uniq.take(QUICK_USE_LIMIT)
    end

    # 品目詳細の「最近の記録」(ItemDetails) を全品目横断にしたもの。
    # 行の描画は同じ部分テンプレート (items/_recent_record) を使い回す
    def dashboard_recent_records
      active = Item.active.select(:id)

      usages = UsageRecord.where(item_id: active)
        .includes(:item, :item_purpose).recent_first.limit(RECENT_RECORDS_LIMIT).to_a
      purchases = Lot.recordable.where(item_id: active)
        .includes(:item, :store).recent_first.limit(RECENT_RECORDS_LIMIT).to_a

      (usages + purchases + dashboard_recent_movements(active))
        .sort_by { |record| [ record.recorded_on, record.created_at ] }
        .reverse
        .take(RECENT_RECORDS_LIMIT)
    end

    # 廃棄と、棚卸の確定で入った調整 (在庫不足の補填は操作ではないので出さない)
    def dashboard_recent_movements(active)
      StockMovement.kind_disposal.or(StockMovement.recorded_adjustments)
        .where(item_id: active)
        .includes(:item, :stock_take_entry).recent_first.limit(RECENT_RECORDS_LIMIT).to_a
    end
end
