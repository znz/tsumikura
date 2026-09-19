# 予測の PORO は Rails のオートロードに頼れないので、依存をここで 1 か所にまとめて読む
# (docs/ops/development.md 4 節)。rails_helper は読まない (DB を使わない)。
require_relative "../../../app/models/forecast/thresholds"
require_relative "../../../app/models/forecast/window"
require_relative "../../../app/models/forecast/pace"
require_relative "../../../app/models/forecast/snapshot"
require_relative "../../../app/models/forecast/result"
require_relative "../../../app/models/forecast/calculator"

# Snapshot は項目が多いので、テストでは注目する値だけを渡せるようにする
module ForecastSpecHelper
  TODAY = Date.new(2026, 9, 19)

  def today
    TODAY
  end

  def snapshot(**overrides)
    Forecast::Snapshot.new(
      quantity: 0,
      minimum_quantity: nil,
      consumed: 0,
      event_count: 0,
      observed_days: 0,
      anchor_on: nil,
      unit_usage: 1,
      mode: :auto,
      manual_interval_days: nil,
      thresholds: Forecast::Thresholds.default,
      today: TODAY,
      **overrides
    )
  end
end
