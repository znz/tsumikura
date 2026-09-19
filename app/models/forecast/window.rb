require "date"

module Forecast
  # 集計窓 (仕様 3 節)。半開区間 (start_on, today] で消費量を集計する
  Window = Data.define(:start_on, :end_on) do
    def self.for(today:, nth_event_on:, last_event_on:, tracking_started_on:, thresholds:)
      # 消費イベントが少ない品目では、直近 window_events 件目のイベント日まで窓を過去へ伸ばす
      candidate = [ today - thresholds.window_min_days, nth_event_on ].compact.min
      # 使い始めて間もない品目のペースを過小評価しないよう tracking_started_on で打ち切り、
      # 2 年より前の生活パターンを持ち込まないよう window_max_days でも打ち切る
      floor_on = [ tracking_started_on, today - thresholds.window_max_days ].compact.max
      start_on = [ candidate, floor_on ].max

      # 窓の開始が消費イベント日で決まったときは、完結した間隔だけで測るため
      # 観測の終わりも消費イベント日 (anchor) に揃える
      end_on = start_on == nth_event_on ? last_event_on : today

      new(start_on: start_on, end_on: end_on)
    end

    def observed_days
      (end_on - start_on).to_i
    end
  end
end
