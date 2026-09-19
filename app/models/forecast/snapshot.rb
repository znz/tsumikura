module Forecast
  # 予測の入力 (仕様 11 節)。AR から値を取り出すのは SnapshotBuilder の仕事で、
  # ここから先は DB にも Rails にも依存しない。today も必ずこの値を使う
  Snapshot = Data.define(
    :quantity,             # q (期限切れロットの残数を除く)
    :minimum_quantity,     # minimum (任意)
    :consumed,             # (window_start, today] の消費量
    :event_count,          # [window_start, today] の消費イベント数
    :observed_days,        # window_end - window_start
    :anchor_on,            # 最後の消費イベント日 (無ければ tracking_started_on)
    :unit_usage,           # u (1 回あたりの使用数の中央値、既定 1)
    :mode,                 # :auto / :manual / :none
    :manual_interval_days,
    :thresholds,
    :today
  )
end
