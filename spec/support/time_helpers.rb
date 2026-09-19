# travel_to / freeze_time を spec から使えるようにする。
# rspec-rails は ActiveSupport::Testing::TimeHelpers を自動では include しない。
# 日付の境界 (未来日の判定) は request / system / task spec でも確かめるので type は絞らない。
RSpec.configure do |config|
  config.include ActiveSupport::Testing::TimeHelpers

  # ブロック無しの travel_to / freeze_time を使ったときに、次の spec へ時間のずれを
  # 持ち越さない。ActiveSupport の after_teardown は Minitest 用で RSpec からは呼ばれない
  # (何も止めていなければ travel_back は何もしない)
  config.after { travel_back }
end
