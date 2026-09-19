class TightenDisposalReasonCheck < ActiveRecord::Migration[8.1]
  # 廃棄の理由は必ず入れる (docs/spec/03-screens.md 1 節)。
  # Phase 7 の制約は「理由が入るのは廃棄だけ」の片側だけだったので、
  # 「廃棄には必ず理由がある」も DB で守る。
  # 理由の無い廃棄は「なんとなく減った」を廃棄で片づけた記録になり、
  # あとから何が起きたのか分からなくなる。
  def up
    remove_check_constraint :stock_movements, name: "stock_movements_disposal_reason_only_for_disposal"
    add_check_constraint :stock_movements, "(kind = 3) = (disposal_reason IS NOT NULL)",
      name: "stock_movements_disposal_reason_matches_kind"
  end

  def down
    remove_check_constraint :stock_movements, name: "stock_movements_disposal_reason_matches_kind"
    add_check_constraint :stock_movements, "disposal_reason IS NULL OR kind = 3",
      name: "stock_movements_disposal_reason_only_for_disposal"
  end
end
