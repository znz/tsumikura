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
  #   - stock_movements.item_id と lots.item_id のずれ (再計算からも検査からも黙って落ちる行)
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
      Item.includes(:lots).find_each.flat_map { |item| differences_for(item) } + mismatched_item_ids
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
        return [] unless lot.kind.in?(Lot::RECORDABLE_KINDS)

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

      # 非正規化した item_id がロットとずれた記録。品目単位の集計から漏れるので、
      # 品目をたどる検査では見つけられない (DB の複合外部キーが本来の防壁)
      def mismatched_item_ids
        StockMovement.joins(:lot).includes(:lot)
          .where("stock_movements.item_id <> lots.item_id").map do |movement|
          Difference.new("在庫の記録 ##{movement.id}", "品目", movement.item_id, movement.lot.item_id)
        end
      end
  end
end
