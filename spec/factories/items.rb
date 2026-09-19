FactoryBot.define do
  factory :item do
    sequence(:name) { |n| "品目#{n}" }
    unit { "個" }

    trait :archived do
      archived_at { Time.current }
    end

    trait :favorite do
      favorite { true }
    end

    trait :tracks_expiry do
      tracks_expiry { true }
    end

    trait :manual_estimation do
      estimation_mode { :manual }
      manual_interval_days { 30 }
    end
  end
end
