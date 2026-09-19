FactoryBot.define do
  factory :user do
    sequence(:email_address) { |n| "family#{n}@example.com" }
    name { "かぞく" }
    password { "password" }

    trait :admin do
      name { "かんりしゃ" }
      role { :admin }
    end

    trait :deactivated do
      deactivated_at { Time.current }
    end
  end
end
