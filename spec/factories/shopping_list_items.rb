FactoryBot.define do
  factory :shopping_list_item do
    item
    association :added_by, factory: :user

    # マスタにない自由入力の行 (品目を持たない)
    trait :free_text do
      item { nil }
      free_text { "じゆうにゅうりょく" }
      added_manually { true }
    end

    trait :manual do
      added_manually { true }
    end

    trait :checked do
      checked_at { Time.current }
    end

    trait :snoozed do
      # 日付は遅延評価にする (読み込み時の日付で固定しない)
      snoozed_until { Date.current + 3 }
    end
  end
end
