FactoryBot.define do
  factory :item_purpose do
    item
    sequence(:name) { |n| "用途#{n}" }
    default_quantity { 1 }

    trait :archived do
      archived_at { Time.current }
    end
  end
end
