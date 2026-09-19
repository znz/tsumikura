# 発行された SQL を順番に記録するヘルパー。
# 「キャッシュを書き換える前に item を行ロックしているか」を確かめるために使う
# (docs/spec/01-domain-model.md 判断 1: 記録の作成・編集・削除は必ず item.lock! の中で)。
module SqlRecorder
  WRITE_STATEMENT = /\A\s*(INSERT|UPDATE|DELETE)\b/i
  IGNORED_NAMES = [ "SCHEMA", "TRANSACTION" ].freeze

  def recorded_sql
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      next if IGNORED_NAMES.include?(payload[:name]) || payload[:cached]

      statements << payload[:sql]
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # 最初の行ロック (SELECT ... FOR UPDATE) の位置
  def first_lock_index(statements)
    statements.index { |sql| sql.include?("FOR UPDATE") }
  end

  # 最初の書き込み (INSERT / UPDATE / DELETE) の位置
  def first_write_index(statements)
    statements.index { |sql| sql.match?(WRITE_STATEMENT) }
  end

  # あるテーブルに行ロック (SELECT ... FOR UPDATE) を掛けた順に、その id を集める。
  # 複数の品目をロックする順番 (デッドロック防止の id 昇順) を確かめるために使う。
  # id はプレースホルダ ($1) になるので SQL の文字列ではなく bind から読む
  # (LIMIT も bind になるので、名前が id のものだけを見る)
  def recorded_lock_ids(table)
    ids = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      next if payload[:cached]
      next unless payload[:sql].include?("FOR UPDATE") && payload[:sql].include?(%("#{table}"))

      ids.concat(Array(payload[:binds]).select { |bind| bind.name.to_s == "id" }.map(&:value))
    end
    yield
    ids
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end

RSpec.configure do |config|
  config.include SqlRecorder, type: :model
end
