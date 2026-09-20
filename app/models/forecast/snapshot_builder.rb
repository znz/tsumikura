module Forecast
  # Item -> Snapshot (docs/spec/02-forecast.md 11 節)。
  #
  # 集計は Aggregator に委譲するので、1 品目でも一覧 (BatchForecaster) でも**同じ式**を通る。
  # today は引数で受け取る (spec で固定できるようにするため。既定は Date.current)
  module SnapshotBuilder
    module_function

    def call(item, today: Date.current)
      Aggregator.new([ item ], today: today).snapshots.fetch(item.id)
    end
  end
end
