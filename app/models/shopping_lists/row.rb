module ShoppingLists
  # 買い物リストの 1 行 (docs/spec/01-domain-model.md 判断 5)。
  #
  # 「要購入判定からの導出 (forecast)」と「ユーザーが手を加えた永続行 (record)」を 1 つに
  # まとめた値オブジェクト。判定だけの行は record が nil で、自由入力の行は item / forecast が
  # nil になる。DB にも Rails にも触らない PORO にして、表示の規則 (推奨数量・並び順) を
  # spec_helper だけで検証できるようにする (Phase 3 の Forecast::Calculator と同じ流儀)。
  class Row < Data.define(:item, :forecast, :record, :today)
    # 自動で並べる判定 (docs/spec/02-forecast.md 14 節: ok と unknown は並べない)
    AUTO_STATUSES = %i[ urgent soon ].freeze

    # 並び順のグループ: urgent → soon → 手動 (品目) → 自由入力。
    # 自動の 2 つは Forecast::Calculator::RANK の悪い順と同じ向きにそろえる
    GROUP_ORDER = { urgent: 0, soon: 1, manual: 2, free_text: 3 }.freeze

    # 推奨数量の既定と上限。上限は Item::MAX_QUANTITY と同じ値
    # (ここは AR を読まない PORO なので定数を持ち、一致は spec で見張る)
    DEFAULT_QUANTITY = 1
    MAX_QUANTITY = 99_999

    def free_text?
      item.nil?
    end

    # 要購入判定から導出された行か (永続行の有無とは関係ない)
    def auto?
      AUTO_STATUSES.include?(status)
    end

    def kind
      return :free_text if free_text?

      auto? ? :auto : :manual
    end

    # 一覧に出す行か。
    # 判定が urgent / soon なら出す。判定が外れても「ユーザーが手を加えたもの」
    # (手動追加・チェック済み) は残す。数量の上書きだけが残った行は出さない
    # (買い終えた品目の上書きが、いつまでも一覧に居座らないように)
    def listed?
      free_text? || checked? || added_manually? || auto?
    end

    def status
      forecast&.status
    end

    def days_left
      forecast&.days_left
    end

    # 判定に使った在庫 (期限切れロットを除いた q)。
    # items.current_quantity を使うと判定した在庫とずれる (docs/spec/02-forecast.md 14 節)
    def stock_quantity
      forecast&.quantity
    end

    def checked?
      !record&.checked_at.nil?
    end

    # 「今回は買わない」。期限が過ぎたスヌーズは行を残したまま無視する
    # (GET に副作用を出さないので、掃除は購入時か日次のジョブで行う)
    def snoozed?
      snoozed_until = record&.snoozed_until
      !snoozed_until.nil? && snoozed_until >= today
    end

    # ユーザーが明示的に足した行か。判定が ok に戻っても消さない目印
    def added_manually?
      !!record&.added_manually
    end

    def quantity_overridden?
      !record&.quantity.nil?
    end

    # 希望数量。手で上書きされていればそれ、無ければ推奨数量
    def quantity
      record&.quantity || recommended_quantity
    end

    # 推奨数量 (docs/spec/01-domain-model.md 判断 5)。
    #
    # 最低在庫数があれば「1 つ上回るまでの不足分」を求め、入数の既定値があればその倍数に
    # 切り上げる (1 パックでは最低在庫数に届かないことがある)。
    # 最低在庫数が無ければ、入数があれば 1 パック、無ければ 1。0 以下にはしない
    def recommended_quantity
      return DEFAULT_QUANTITY if free_text?

      pack_size = item.default_pack_size
      pack_size = nil unless pack_size.nil? || pack_size.positive?
      shortfall = item.minimum_quantity.nil? ? nil : item.minimum_quantity - stock_quantity.to_i + 1

      clamp(quantity_for(shortfall, pack_size))
    end

    def name
      free_text? ? record.free_text : item.name
    end

    def unit
      item&.unit
    end

    def item_id
      item&.id
    end

    def record_id
      record&.id
    end

    # 行の DOM id。**永続行の有無では変わらない** ようにする。
    # チェックで行が作られたり、チェックを外して行が消えたりするたびに id が変わると、
    # リダイレクト先のアンカーも morph の対応付けも外れてスクロール位置が飛ぶ
    def dom_id
      self.class.dom_id(item_id: item_id, record_id: record_id)
    end

    # 永続行 (ShoppingListItem) 側からも同じ id を組み立てられるようにする
    def self.dom_id(item_id:, record_id: nil)
      item_id ? "shopping_list_row_item_#{item_id}" : "shopping_list_row_entry_#{record_id}"
    end

    # 並び順のキー: グループ → days_left (nil は最後) → よみ → id
    def sort_key
      [ GROUP_ORDER.fetch(auto? ? status : kind), days_left.nil? ? 1 : 0, days_left || 0,
        sort_name, record_id || item_id || 0 ]
    end

    private
      def sort_name
        return record.free_text.to_s if free_text?

        name_reading = item.name_reading
        name_reading.nil? || name_reading.empty? ? item.name.to_s : name_reading
      end

      # 不足分 (shortfall) と入数 (pack_size) から買う数を決める。
      # 不足分が入数で割り切れなくても足りるよう、パック数は切り上げる
      def quantity_for(shortfall, pack_size)
        return pack_size || DEFAULT_QUANTITY if shortfall.nil?
        return shortfall if pack_size.nil?

        [ (shortfall + pack_size - 1) / pack_size, 1 ].max * pack_size
      end

      def clamp(quantity)
        quantity.clamp(DEFAULT_QUANTITY, MAX_QUANTITY)
      end
  end
end
