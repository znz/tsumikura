FactoryBot.define do
  factory :storage_location do
    sequence(:name) { |n| "保管場所#{n}" }
  end
end
