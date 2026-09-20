module Expiry
  # ロット 1 件の期限ステータス (docs/spec/02-forecast.md 12 節)。
  #
  # 予測 (Forecast) と同じく、ここは DB にも Rails にも依存しない純粋関数にする
  # (spec_helper だけで回せる)。today は必ず引数で受け取る。
  module Status
    EXPIRED = :expired
    EXPIRING_SOON = :expiring_soon
    FRESH = :fresh

    # 品目のステータスは保有ロットの**最悪値**を採るので、悪さの順位を持つ
    RANK = { FRESH => 0, EXPIRING_SOON => 1, EXPIRED => 2 }.freeze

    module_function

    def for(expires_on:, today:, warning_days:)
      # 期限を入れていないロット (棚卸のプラス差分で作る調整ロットなど) は判定しない
      return FRESH if expires_on.nil?
      # 期限日の当日はまだ期限切れではない (Lot#expired? / Stock::Allocator と同じ基準)
      return EXPIRED if expires_on < today
      return EXPIRING_SOON if expires_on <= today + warning_days

      FRESH
    end

    # 保有ロットの最悪値。1 件も無ければ FRESH (知らせることが無い)
    def worst(statuses)
      statuses.max_by { |status| RANK.fetch(status) } || FRESH
    end
  end
end
