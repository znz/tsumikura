module Forecast
  # 要購入判定の結果 (仕様 11 節)。
  # status: :ok / :soon / :urgent / :unknown、reason: :pace / :minimum / :out_of_stock / :no_data
  Result = Data.define(:status, :pace, :need_by_on, :days_left, :reason)
end
