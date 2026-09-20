module Forecast
  # Item の Relation -> { item_id => Result } (docs/spec/02-forecast.md 11 節)。
  #
  # 品目一覧・ダッシュボードのように N 件をまとめて判定するときに使う。集計は Aggregator が
  # 定数回のクエリで取るので、品目が増えてもクエリは増えない (N+1 にしない)。
  # 結果は ItemForecaster で 1 件ずつ判定したものと必ず一致する (同じ Snapshot を通るため)。
  #
  # アーカイブ済みの品目は予測しない (仕様 9 節: 一覧・ダッシュボード・買い物リストから除外)
  # ので、結果のハッシュにも入らない。呼び出し側は `forecasts[item.id]` が nil になりうる
  # 前提で書く (バッジを出さない)。
  module BatchForecaster
    module_function

    def call(items, today: Date.current)
      targets = Array(items).reject(&:archived?)

      Aggregator.new(targets, today: today).snapshots.transform_values { Calculator.call(_1) }
    end
  end
end
