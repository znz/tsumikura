# 買い物リストの PORO は Rails のオートロードに頼れないので、依存をここで 1 か所にまとめて読む
# (docs/ops/development.md 4 節、Phase 3 の spec/models/forecast/forecast_helper.rb と同じ流儀)。
# rails_helper は読まない (DB を使わない)。
require "date"
require_relative "../../../app/models/forecast/result"
require_relative "../../../app/models/shopping_lists/row"
require_relative "../../../app/models/shopping_lists/list"
require_relative "../../../app/models/shopping_lists/merger"

# Merger が読むのは「素の属性」だけなので、AR を読み込まずに Struct で代用できる。
# (実物の Item / ShoppingListItem / Forecast::Result と同じ名前のメソッドだけを持たせる)
module ShoppingListSpecHelper
  TODAY = Date.new(2026, 9, 20)

  FakeItem = Struct.new(:id, :name, :name_reading, :unit, :default_pack_size, :minimum_quantity,
    keyword_init: true)

  FakeRecord = Struct.new(:id, :item_id, :free_text, :quantity, :checked_at, :snoozed_until,
    :added_manually, keyword_init: true)

  def today
    TODAY
  end

  def item(id:, name: "しなもの#{id}", **overrides)
    FakeItem.new(id: id, name: name, unit: "個", **overrides)
  end

  def record(item_id: nil, **overrides)
    FakeRecord.new(id: 900 + (item_id || 0), item_id: item_id, added_manually: false, **overrides)
  end

  # Forecast::Result のうち、買い物リストが読む値だけを指定できるようにする
  def forecast(status:, days_left: nil, quantity: 0)
    Forecast::Result.new(status: status, pace: nil, need_by_on: nil, days_left: days_left,
      reason: :pace, quantity: quantity)
  end

  # Enumerable#sole は ActiveSupport なので、ここ (rails_helper を読まない spec) では使えない
  def only_row(list)
    expect(list.rows.size).to eq 1
    list.rows.first
  end

  def merge(items: [], forecasts: {}, records: [])
    ShoppingLists::Merger.call(items: items, forecasts: forecasts, records: records, today: today)
  end
end
