FactoryBot.define do
  factory :stock_take_entry do
    stock_take
    item
    expected_quantity { 0 }
    counted_quantity { 0 }
    # difference は StockTakeEntry#apply_difference が counted - expected から入れる
  end
end
