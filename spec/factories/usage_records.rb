FactoryBot.define do
  factory :usage_record do
    item
    user
    quantity { 1 }
    # 日付は遅延評価にする (読み込み時の日付で固定しない)
    used_on { Date.current }

    transient do
      # 台帳を作らない (ずれた状態を作りたい spec だけ false にする)
      with_movements { true }
    end

    # 在庫の正は台帳 (stock_movements) なので、ファクトリでも引き当てて movement を作り、
    # キャッシュ (lots.remaining_quantity / items.current_quantity) を再計算しておく。
    # 在庫が足りなければ補填の調整ロットができる (Stock::Allocator と同じ挙動)
    after(:create) do |usage_record, evaluator|
      next unless evaluator.with_movements

      Stock::UsageMovements.write!(usage_record)
      Stock::Recalculator.call(usage_record.item)
    end
  end
end
