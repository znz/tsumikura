FactoryBot.define do
  factory :stock_movement do
    lot
    # item は lot 経由でも辿れるが、集計用に非正規化しているので必ずそろえる
    item { lot.item }
    user { lot.user }
    kind { :purchase }
    quantity { 1 }
    occurred_on { Date.current }
  end
end
