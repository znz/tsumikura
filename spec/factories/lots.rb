FactoryBot.define do
  factory :lot do
    item
    user
    kind { :purchase }
    acquired_on { Date.current }
    initial_quantity { 1 }

    transient do
      # キャッシュがずれた状態を作りたい spec だけ false にする
      with_movement { true }
    end

    # 在庫の正は台帳 (stock_movements) なので、ファクトリでも入庫の movement を作り、
    # キャッシュ (lots.remaining_quantity / items.current_quantity) を再計算しておく
    after(:create) do |lot, evaluator|
      next unless evaluator.with_movement

      lot.stock_movements.create!(item: lot.item, user: lot.user, kind: :purchase,
        quantity: lot.initial_quantity, occurred_on: lot.acquired_on)
      Stock::Recalculator.call(lot.item)
      lot.reload
    end

    trait :initial do
      kind { :initial }
    end

    trait :adjustment do
      kind { :adjustment }
    end
  end
end
