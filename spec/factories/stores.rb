FactoryBot.define do
  factory :store do
    sequence(:name) { |n| "お店#{n}" }
  end
end
