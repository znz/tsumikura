module Forecast
  # 要購入判定の結果 (仕様 11 節)。
  # status: :ok / :soon / :urgent / :unknown、reason: :pace / :minimum / :out_of_stock / :no_data
  #
  # quantity は判定に使った在庫 q (**期限切れロットを除いた数**)。
  # items.current_quantity とは違うので、画面や買い物リスト (Phase 11) が
  # 「在庫 n」や推奨数量を出すときはこちらを使う (でないと期限切れのぶんだけずれる)。
  Result = Data.define(:status, :pace, :need_by_on, :days_left, :reason, :quantity)
end
