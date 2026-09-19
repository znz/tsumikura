module Stock
  # 棚卸の下書きに実数を書き込む (docs/spec/03-screens.md 画面 6)。
  # 途中保存できるよう、画面を開いただけでは明細を作らず、
  # **入力された品目のぶんだけ**明細を作る (未入力 = 明細なし = 確定でスキップ)。
  # 空で送り直せば明細は消える (入力の取り消し)。
  #
  # ロット別に数えた品目は、合計の入力を使わずロット別の明細だけを残す
  # (より細かいほうを採る)。画面にもその旨を出す。
  #
  # **送られた値が元の値 (was) と同じ欄には触らない。** フォームは全品目を送るので、
  # そのまま書くと、別のタブや別の人が先に入れた実数を空欄で上書き (削除) してしまう。
  #
  # 下書きは在庫にいっさい触らないので台帳や品目のロックは要らないが、
  # **ヘッダは lock! する**。確定と同時に走ると、movement は古い差分のままで
  # 明細だけが変わり「差分 ≠ movements の合計」が残ってしまう。
  # expected_quantity は確認画面に出すための下書き時点の記録在庫で、
  # 確定 (Stock::FinalizeStockTake) が取り直す。
  #
  # 戻り値は真偽値。数字でない実数が送られたら何も書かずに false を返す
  # (入力を失わせないよう、画面は送られた値のまま描き直す)。
  # ロックの後に確定済みだと分かったら ActiveRecord::RecordNotFound
  # (確定済みの棚卸を編集しようとしたときと同じ 404)。
  class WriteStockTakeEntries
    COUNT_PATTERN = /\A[0-9]+\z/

    def self.call(stock_take, counts:)
      new(stock_take, counts: counts).call
    end

    def initialize(stock_take, counts:)
      @stock_take = stock_take
      @counts = counts.is_a?(Hash) ? counts : {}
      @items = stock_take.target_items.to_a
      @lots_by_item_id = Lot.where(item_id: @items.map(&:id)).to_a.group_by(&:item_id)
    end

    def call
      return false unless submitted_values.all? { |value| acceptable?(value) }

      ApplicationRecord.transaction do
        # 確定済みかの判定はロックの「あと」でなければ意味がない
        stock_take.lock!
        if stock_take.finalized?
          raise ActiveRecord::RecordNotFound, "棚卸 ##{stock_take.id} はすでに確定しています"
        end

        items.each { |item| write_item(item) }
      end
      true
    end

    private
      attr_reader :stock_take, :counts, :items, :lots_by_item_id

      def existing_entries
        @existing_entries ||= stock_take.stock_take_entries.to_a
          .index_by { |entry| [ entry.item_id, entry.lot_id ] }
      end

      def submitted_values
        items.flat_map { |item| [ total_value(item), *lot_values(item).values ] }
      end

      # 0 以上の整数か空だけを受け付ける。上限が無いと 4 バイト整数をはみ出した入力が
      # 書き込み時に RangeError になり 422 ではなく 500 になる
      def acceptable?(value)
        value.blank? || (value.match?(COUNT_PATTERN) && value.to_i <= Item::MAX_QUANTITY)
      end

      def write_item(item)
        lot_values(item).each { |lot_id, value| write_entry(item, lot_id, value) }
        write_entry(item, nil, total_value(item))
        drop_total_counted_by_lot(item)
      end

      # 書き換えられた欄だけを反映する。送られた値が元の値 (was) と同じなら、
      # その欄は「触っていない」とみなして何もしない
      def write_entry(item, lot_id, value)
        return if same_as_before?(value, was_value(item, lot_id))

        key = [ item.id, lot_id ]
        entry = existing_entries[key]

        if value.blank?
          entry&.destroy!
          existing_entries.delete(key)
        else
          entry ||= stock_take.stock_take_entries.new(item: item, lot_id: lot_id)
          entry.update!(expected_quantity: expected_quantity_for(item, lot_id),
            counted_quantity: value.to_i)
          existing_entries[key] = entry
        end
      end

      # 同じ品目をロット別にも数えていたら、合計の明細は落とす (二重に数えないため)。
      # より細かいロット別のほうを採る (docs/spec/01-domain-model.md 判断 3)
      def drop_total_counted_by_lot(item)
        total = existing_entries[[ item.id, nil ]]
        return if total.nil?
        return if existing_entries.none? { |(item_id, lot_id), _| item_id == item.id && lot_id.present? }

        total.destroy!
        existing_entries.delete([ item.id, nil ])
      end

      def expected_quantity_for(item, lot_id)
        return item.current_quantity if lot_id.nil?

        (lots_by_item_id[item.id] || []).find { |lot| lot.id == lot_id }.remaining_quantity
      end

      def same_as_before?(value, was)
        normalize(value) == normalize(was)
      end

      def normalize(value)
        value.is_a?(String) ? value.strip : ""
      end

      def item_counts(item)
        value = counts[item.id.to_s]
        value.is_a?(Hash) ? value : {}
      end

      def total_value(item)
        string_value(item_counts(item)["total"])
      end

      # 画面に出ていた元の値 (hidden)。壊れた形で送られても Hash 以外はたどらない
      def was_value(item, lot_id)
        counts = item_counts(item)
        return string_value(counts["was"]) if lot_id.nil?

        raw = counts["lots_was"]
        raw.is_a?(Hash) ? string_value(raw[lot_id.to_s]) : nil
      end

      def string_value(value)
        value.is_a?(String) ? value.strip : nil
      end

      # 知らないロット id は黙って捨てる (他の品目のロットは数えられない)
      def lot_values(item)
        raw = item_counts(item)["lots"]
        return {} unless raw.is_a?(Hash)

        ids = (lots_by_item_id[item.id] || []).map(&:id)
        raw.filter_map { |lot_id, value|
          id = Integer(lot_id.to_s, 10, exception: false)
          next unless id && ids.include?(id)

          [ id, string_value(value) ]
        }.to_h
      end
  end
end
