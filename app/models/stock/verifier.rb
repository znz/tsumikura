module Stock
  # キャッシュ列と台帳 (stock_movements) の差異を集める (rake stock:verify)。
  # キャッシュが壊れても台帳から必ず復元できることを担保するための検査で、
  # 直すのは Stock::Recalculator (rake stock:recalculate) の役目
  # (docs/spec/01-domain-model.md 判断 1)。
  #
  # 検出するもの:
  #   - lots.remaining_quantity / lots.depleted_at
  #   - items.current_quantity / tracking_started_on / last_consumed_on
  #   - 入庫の movement とロットの数量・日付のずれ (再計算では直らない)
  #   - stock_movements.item_id と lots.item_id / usage_records.item_id のずれ
  #     (再計算からも検査からも黙って落ちる行)
  #   - usage_records の数量・日付と、紐づく movement のずれ (二重管理のずれ)
  #   - 使用記録に紐づかない使用の movement (どの操作で減ったか分からない行)
  #   - 使用記録に紐づく movement の種別の不整合 (使用と補填の入庫だけのはず)
  #   - 補填の調整ロットの合計が 0 でないもの (補填した分をそのまま使い切るはず)
  class Verifier
    Difference = Struct.new(:subject, :attribute, :cached, :actual) do
      def to_s
        "#{subject}: #{attribute} キャッシュ=#{display(cached)} 台帳=#{display(actual)}"
      end

      def display(value)
        value.nil? ? "なし" : value.to_s
      end
    end

    def self.call
      new.call
    end

    def call
      Item.includes(:lots).find_each.flat_map { |item| differences_for(item) } +
        mismatched_item_ids + usage_record_differences + usage_movement_differences +
        unbalanced_compensating_lots
    end

    private
      def differences_for(item)
        movements = StockMovement.where(item_id: item.id)
        totals = movements.group(:lot_id).sum(:quantity)
        inbound = movements.where(quantity: 1..).order(:id).group_by(&:lot_id)
        current_quantity = 0

        differences = item.lots.flat_map { |lot|
          remaining = totals[lot.id].to_i
          current_quantity += remaining

          lot_differences(item, lot, remaining) + inbound_differences(item, lot, inbound[lot.id]&.first)
        }

        differences + item_differences(item, movements, current_quantity)
      end

      def lot_differences(item, lot, remaining)
        subject = "#{item.name} のロット ##{lot.id}"
        differences = []

        unless lot.remaining_quantity == remaining
          differences << Difference.new(subject, "残数", lot.remaining_quantity, remaining)
        end

        # 残 0 のロットは畳むための depleted_at を打ち、残が戻ったら消す
        expected_depleted = !remaining.positive?
        unless lot.depleted? == expected_depleted
          differences << Difference.new(subject, "使い切った日時", lot.depleted_at,
            expected_depleted ? "残 0 なので必要" : "残があるので不要")
        end

        differences
      end

      # 入庫の movement はロットの数量・日付と一致していなければならない。
      # ここがずれると再計算しても直らない (台帳が正なので在庫だけが静かに変わる)
      def inbound_differences(item, lot, movement)
        return [] unless lot.recordable?

        subject = "#{item.name} のロット ##{lot.id}"
        return [ Difference.new(subject, "入庫の記録", lot.initial_quantity, nil) ] if movement.nil?

        differences = []
        unless lot.initial_quantity == movement.quantity
          differences << Difference.new(subject, "入庫の数量", lot.initial_quantity, movement.quantity)
        end
        unless lot.acquired_on == movement.occurred_on
          differences << Difference.new(subject, "入庫の日付", lot.acquired_on, movement.occurred_on)
        end

        differences
      end

      def item_differences(item, movements, current_quantity)
        expected = {
          "在庫数" => [ item.current_quantity, current_quantity ],
          "記録開始日" => [ item.tracking_started_on, movements.minimum(:occurred_on) ],
          "最終消費日" => [ item.last_consumed_on, movements.consumption.maximum(:occurred_on) ]
        }

        expected.filter_map do |attribute, (cached, actual)|
          Difference.new("品目「#{item.name}」", attribute, cached, actual) unless cached == actual
        end
      end

      # 使用記録の数量は、紐づく出庫 movement の合計と一致していなければならない
      # (在庫不足を補填した入庫 movement は数に入れない)。日付も同じ。
      # ここがずれると「使った数」と在庫の減り方が食い違い、どちらが正か分からなくなる
      def usage_record_differences
        UsageRecord.includes(:item, :stock_movements).find_each.flat_map do |record|
          subject = "品目「#{record.item.name}」の使用の記録 ##{record.id}"
          movements = record.stock_movements
          consumed = -movements.sum { |movement| [ movement.quantity, 0 ].min }
          differences = []

          unless record.quantity == consumed
            differences << Difference.new(subject, "使用の数量", record.quantity, consumed)
          end

          mismatched = movements.find { |movement| movement.occurred_on != record.used_on }
          if mismatched
            differences << Difference.new(subject, "使用の日付", record.used_on, mismatched.occurred_on)
          end

          differences
        end
      end

      # 非正規化した item_id がロット・使用記録とずれた記録。品目単位の集計から漏れるので、
      # 品目をたどる検査では見つけられない (DB の複合外部キーが本来の防壁)
      def mismatched_item_ids
        StockMovement.joins(:lot).includes(:lot)
          .where("stock_movements.item_id <> lots.item_id").map { |movement|
          Difference.new("在庫の記録 ##{movement.id}", "品目", movement.item_id, movement.lot.item_id)
        } +
          StockMovement.joins(:usage_record).includes(:usage_record)
            .where("stock_movements.item_id <> usage_records.item_id").map do |movement|
            Difference.new("在庫の記録 ##{movement.id}", "使用記録の品目",
              movement.item_id, movement.usage_record.item_id)
          end
      end

      # 使用の movement は必ず使用記録に紐づく (どの操作で減ったか分からなくなるうえ、
      # 使用記録からの編集・削除でも直せない行になる)。
      # 逆に、使用記録に紐づく movement は「使用」か「補填の入庫 (正の adjustment)」だけ
      def usage_movement_differences
        orphans = StockMovement.kind_usage.where(usage_record_id: nil).includes(:item).map { |movement|
          Difference.new("品目「#{movement.item.name}」の在庫の記録 ##{movement.id}",
            "使用記録", nil, "使用の記録には必要")
        }

        orphans + StockMovement.where.not(usage_record_id: nil)
          .where.not("kind = ? OR (kind = ? AND quantity > 0)",
            StockMovement.kinds[:usage], StockMovement.kinds[:adjustment])
          .includes(:item).map do |movement|
          Difference.new("品目「#{movement.item.name}」の在庫の記録 ##{movement.id}",
            "使用記録に紐づく種別", movement.kind, "使用または補填の入庫")
        end
      end

      # 在庫不足を補填した調整ロットは、補填した分をそのまま使い切るので
      # movements の合計は必ず 0 になる。0 でなければ実在しない在庫が残っている
      def unbalanced_compensating_lots
        lot_ids = StockMovement.kind_adjustment.where(quantity: 1..)
          .where.not(usage_record_id: nil).distinct.pluck(:lot_id)
        return [] if lot_ids.empty?

        totals = StockMovement.where(lot_id: lot_ids).group(:lot_id).sum(:quantity)

        Lot.where(id: lot_ids).includes(:item).filter_map do |lot|
          total = totals[lot.id].to_i
          next if total.zero?

          Difference.new("品目「#{lot.item.name}」の補填の調整ロット ##{lot.id}", "残数", total, 0)
        end
      end
  end
end
