module ShoppingLists
  # 「要購入判定からの導出」と「永続行」を 1 つのリストにマージする純粋関数
  # (docs/spec/01-domain-model.md 判断 5)。
  #
  # DB には触らない (読み込みは Builder の仕事)。items は判定の対象になった品目 (アーカイブ済みを
  # 含まない)、forecasts は Forecast::BatchForecaster の結果、records は shopping_list_items。
  # GET で行を作らないので、ここでも永続行は読むだけで書かない。
  module Merger
    module_function

    def call(items:, forecasts:, records:, today:)
      records_by_item_id, free_text_records = split(records)

      rows = items.filter_map { |item|
        row = Row.new(item: item, forecast: forecasts[item.id],
          record: records_by_item_id[item.id], today: today)
        row if row.listed?
      }
      rows += free_text_records.map { |record|
        Row.new(item: nil, forecast: nil, record: record, today: today)
      }

      # スヌーズ中の行は畳んで見せる。ただしチェック済み (買うと決めた) なら一覧に残す
      listed, snoozed = rows.partition { |row| !row.snoozed? || row.checked? }
      List.new(rows: sorted(listed), snoozed_rows: sorted(snoozed))
    end

    # 品目に紐づく行は品目 1 件につき 1 行 (部分一意 index)。item_id が nil の行は自由入力
    def split(records)
      by_item_id = {}
      free_text = []

      records.each do |record|
        record.item_id.nil? ? free_text << record : by_item_id[record.item_id] = record
      end

      [ by_item_id, free_text ]
    end

    def sorted(rows)
      rows.sort_by(&:sort_key)
    end
  end
end
