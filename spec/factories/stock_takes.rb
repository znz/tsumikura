FactoryBot.define do
  factory :stock_take do
    user
    # 日付は遅延評価にする (読み込み時の日付で固定しない)
    counted_on { Date.current }

    # 確定済み。在庫を動かすのは Stock::FinalizeStockTake なので、
    # 「確定済みの見た目」だけが要る spec でこれを使う
    trait :finalized do
      finalized_at { Time.current }
    end
  end
end
