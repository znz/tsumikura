# 予測の spec 用に「n 日おきに m 回使った品目」を作るヘルパー。
#
# 予測は台帳 (stock_movements / usage_records) とキャッシュ列
# (items.last_consumed_on / tracking_started_on) の両方を読むので、
# 記録は必ず Phase 8 / 9 のサービスと同じ経路 (usage_record ファクトリ →
# Stock::UsageMovements → Stock::Recalculator) で作る。
#
# 在庫が足りない使用は Stock::Allocator が補填する。補填の入庫は**正の adjustment** なので
# 消費 (StockMovement.consumption) には入らず、ペースの分子は歪まない
# (docs/spec/01-domain-model.md 5 節の申し送り)。
module StockHistoryHelper
  # interval 日おきに times 回使う。最新の使用は last_used_days_ago 日前。
  # 戻り値は新しい順の UsageRecord の配列
  def record_usages(item, interval:, times:, last_used_days_ago: 0, quantity: 1, user: nil)
    user ||= create(:user)
    records = Array.new(times) do |index|
      create(:usage_record, item: item, user: user, quantity: quantity,
        used_on: Date.current - last_used_days_ago - (interval * index))
    end
    Stock::Recalculator.call(item)
    records
  end

  # 使用の記録を 1 件だけ足す (日付と数量を細かく指定したいとき)
  def record_usage(item, days_ago: 0, quantity: 1, user: nil, **attributes)
    record = create(:usage_record, item: item, user: user || create(:user), quantity: quantity,
      used_on: Date.current - days_ago, **attributes)
    Stock::Recalculator.call(item)
    record
  end

  # 在庫を積む (購入のロット)。期限を指定すれば期限判定の対象になる
  def stock_up(item, quantity, days_ago: 0, **attributes)
    lot = create(:lot, item: item, initial_quantity: quantity,
      acquired_on: Date.current - days_ago, **attributes)
    Stock::Recalculator.call(item)
    lot
  end

  # 棚卸のマイナス差分 (消費に入るが u には入らない)。
  # 確定済みの棚卸を通すので、movement の日付は棚卸日になる
  def count_stock(item, counted_quantity, days_ago: 0, user: nil)
    user ||= create(:user)
    stock_take = create(:stock_take, user: user, counted_on: Date.current - days_ago)
    written = Stock::WriteStockTakeEntries.call(stock_take, counts: {
      item.id.to_s => { "total" => counted_quantity.to_s }
    })
    raise "棚卸の実数を書き込めなかった (#{counted_quantity.inspect})" unless written

    Stock::FinalizeStockTake.call(stock_take, user: user)
    item.reload
    stock_take
  end

  # 廃棄 (消費には入らない)
  def dispose(item, quantity, days_ago: 0, reason: :expired, user: nil, **attributes)
    user ||= create(:user)
    result = Stock::RecordDisposal.call(item: item, user: user, attributes: {
      quantity: quantity, occurred_on: Date.current - days_ago, disposal_reason: reason, **attributes
    })
    # 在庫が足りないと廃棄は検証エラーになる (補填しない)。黙って通すと spec の意図がずれる
    raise "廃棄を記録できなかった (#{result.errors.full_messages.to_sentence})" if result.movements.blank?

    item.reload
    result
  end
end

RSpec.configure do |config|
  config.include StockHistoryHelper, type: :model
  config.include StockHistoryHelper, type: :request
  config.include StockHistoryHelper, type: :system
end
