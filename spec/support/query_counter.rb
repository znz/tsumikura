# N+1 を見張るための素朴なクエリカウンタ。
# 「レコードを増やしてもクエリ数が変わらないこと」を確かめる用途にだけ使う。
module QueryCounter
  IGNORED_NAMES = [ "SCHEMA", "TRANSACTION" ].freeze

  def count_queries
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      count += 1 unless IGNORED_NAMES.include?(payload[:name]) || payload[:cached]
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end

RSpec.configure do |config|
  config.include QueryCounter, type: :request
end
