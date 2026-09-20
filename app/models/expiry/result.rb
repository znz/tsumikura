module Expiry
  # 品目 1 件の期限の状態 (docs/spec/02-forecast.md 12 節)。
  # status は保有ロットの最悪値、残りは画面に出す内訳 (最も近い期限・期限切れの数)。
  Result = Data.define(:status, :expired_count, :expiring_soon_count, :nearest_expires_on) do
    def expired?
      status == Status::EXPIRED
    end

    def expiring_soon?
      status == Status::EXPIRING_SOON
    end

    def fresh?
      status == Status::FRESH
    end
  end
end
