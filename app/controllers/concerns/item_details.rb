# 品目詳細 (在庫・ロット・用途・最近の記録) の読み込み。
# ItemsController#show と、ワンタップ使用の Turbo Stream 応答
# (Items::QuickUsesController) が同じ描画を共有するためにここにまとめる。
module ItemDetails
  extend ActiveSupport::Concern

  # 使い切ったロットは畳んで表示するので、一覧に出すのは直近の分だけにする
  # (何年も使っている品目で行が無限に伸びないように)
  DEPLETED_LOTS_LIMIT = 20
  # 「最近の記録」に出す件数。これを超えたら全履歴 (Items::RecordsController) へ誘導する
  RECENT_RECORDS_LIMIT = 10

  private
    def load_item_detail(item, today: Date.current)
      @item = item
      # 「今日」は 1 リクエストにつき 1 回だけ取る。予測・期限・FEFO の並び・ロットの
      # 期限切れ表示がそれぞれ Date.current を呼ぶと、0 時をまたいだ瞬間に
      # 「在庫 q からは除いたのにバッジは期限切れでない」といったずれが出る
      @today = today
      # 予測 (在庫切れ予測日・ペース・判定理由) と期限のステータス。
      # ワンタップ使用の応答でも引くので、一覧の行のバッジが記録の直後に更新される
      @forecast = Forecast::ItemForecaster.call(@item, today: @today)
      @expiry = Expiry::Evaluator.for(@item, today: @today)
      load_lots
      load_purposes
      load_recent_records
    end

    # ロット一覧は期限が近い順 (FEFO)。store を includes しないと行ごとに店舗を引いてしまう
    def load_lots
      @available_lots = @item.lots.available.includes(:store).fefo(@today).to_a
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

    # 使用・購入・廃棄・棚卸の調整の時系列は全履歴 (Items::RecordsController) と共有する
    # (Stock::RecordHistory)。
    # 「もっと見る」の判定のために **1 件多く**引く。総件数の COUNT を足すより、
    # 各テーブルから 1 行多く読むほうが安い (クエリの本数は変わらない)
    def load_recent_records
      records = Stock::RecordHistory.call(@item, limit: RECENT_RECORDS_LIMIT + 1)
      @recent_records = records.take(RECENT_RECORDS_LIMIT)
      # 11 件目が引けたときだけ全履歴への導線を出す (件数は出さない)
      @recent_records_truncated = records.size > RECENT_RECORDS_LIMIT
    end
end
