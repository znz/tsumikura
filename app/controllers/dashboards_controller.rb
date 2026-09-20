class DashboardsController < ApplicationController
  include DashboardSummary

  # ダッシュボード (docs/spec/03-screens.md 画面 1)。
  # (1) アラートカード 4 種 (2) クイック使用 (3) 最近の記録。
  # 集計は DashboardSummary (ワンタップ使用の Turbo Stream 応答と共用)
  def show
    load_dashboard_summary
  end
end
