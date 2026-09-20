module Forecast
  # Item -> Result (docs/spec/02-forecast.md 11 節)。SnapshotBuilder と Calculator の合成。
  #
  # 品目詳細とワンタップ使用の応答が使う。一覧・ダッシュボードのように複数の品目を
  # まとめて判定するときは BatchForecaster を使う (クエリ数が品目数に比例しない)。
  module ItemForecaster
    module_function

    def call(item, today: Date.current)
      Calculator.call(SnapshotBuilder.call(item, today: today))
    end
  end
end
