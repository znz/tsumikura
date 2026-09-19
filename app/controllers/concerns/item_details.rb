# 品目詳細 (在庫・ロット・用途・最近の記録) の読み込み。
# ItemsController#show と、ワンタップ使用の Turbo Stream 応答
# (Items::QuickUsesController) が同じ描画を共有するためにここにまとめる。
module ItemDetails
  extend ActiveSupport::Concern

  # 使い切ったロットは畳んで表示するので、一覧に出すのは直近の分だけにする
  # (何年も使っている品目で行が無限に伸びないように)
  DEPLETED_LOTS_LIMIT = 20
  # 「最近の記録」に出す使用・購入の件数
  RECENT_RECORDS_LIMIT = 10

  private
    def load_item_detail(item)
      @item = item
      load_lots
      load_purposes
      @recent_records = recent_records
    end

    # ロット一覧は期限が近い順 (FEFO)。store を includes しないと行ごとに店舗を引いてしまう
    def load_lots
      @available_lots = @item.lots.available.includes(:store).fefo.to_a
      @depleted_lots_count = @item.lots.depleted.count
      @depleted_lots = @item.lots.depleted.includes(:store).recent_first.limit(DEPLETED_LOTS_LIMIT).to_a
      # 「最近の単価」は価格のある直近のロットだけで計算する (docs/spec/01-domain-model.md 判断 6)
      @average_unit_price_yen =
        Lot.average_unit_price_yen(@item.lots.priced.recent_first.limit(Lot::RECENT_PRICED_LOTS))
    end

    # 用途ごとの最終使用日・交換周期を出すので、使用記録まで先読みする
    # (用途が増えてもクエリ数を増やさない)
    def load_purposes
      @purposes = @item.tracks_purposes? ? @item.item_purposes.active.includes(:usage_records).to_a : []
    end

    # 使用と購入を時系列で混ぜる。調整ロット (在庫不足の補填・棚卸) は
    # ユーザーの操作ではないので出さない。
    # 行ごとに用途・店舗を出すので、どちらも includes しないと記録の数だけクエリが増える
    def recent_records
      usages = @item.usage_records.includes(:item_purpose).recent_first.limit(RECENT_RECORDS_LIMIT).to_a
      purchases = @item.lots.recordable.includes(:store).recent_first.limit(RECENT_RECORDS_LIMIT).to_a

      (usages + purchases)
        .sort_by { |record| [ record.recorded_on, record.created_at ] }
        .reverse
        .take(RECENT_RECORDS_LIMIT)
    end
end
