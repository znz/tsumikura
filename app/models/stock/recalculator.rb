module Stock
  # 品目 1 件のキャッシュ列を台帳 (stock_movements) から作り直す
  # (docs/spec/01-domain-model.md 判断 1)。
  #
  #   lot.remaining_quantity == lot.stock_movements.sum(:quantity)
  #   item.current_quantity  == item.lots.sum(:remaining_quantity)
  #
  # 記録の作成・編集・削除は必ず同一トランザクション内で item.lock! してからここを通す。
  # 差分更新 (increment_counter) にしないのは、ずれたときに直せなくなるため。
  # 品目単位の全再計算なので、キャッシュが壊れても rake stock:recalculate で必ず復元できる。
  class Recalculator
    def self.call(item)
      new(item).call
    end

    def initialize(item)
      @item = item
    end

    def call
      # すでにトランザクションの中で呼ばれていれば、そのトランザクションに乗る
      Item.transaction do
        # 同じ品目への同時操作を直列化する。ロックの外で集計すると取りこぼす
        item.lock!
        recalculate_item(recalculate_lots)
      end
      item
    end

    private
      attr_reader :item

      # ロットごとの残数を台帳から入れ直し、品目全体の在庫数を返す
      def recalculate_lots
        totals = StockMovement.where(item_id: item.id).group(:lot_id).sum(:quantity)
        current_quantity = 0

        item.lots.reload.each do |lot|
          remaining = totals[lot.id].to_i
          write_lot(lot, remaining)
          current_quantity += remaining
        end

        current_quantity
      end

      def write_lot(lot, remaining)
        # 残 0 のロットは depleted_at を打って一覧から畳む (物理削除はしない)。
        # 記録の削除・編集で残が戻ることがあるので、その場合は depleted_at を消す
        depleted_at = remaining.positive? ? nil : (lot.depleted_at || Time.current)
        return if lot.remaining_quantity == remaining && lot.depleted_at == depleted_at

        # キャッシュの書き戻しで updated_at は汚さない
        lot.update_columns(remaining_quantity: remaining, depleted_at: depleted_at)
      end

      def recalculate_item(current_quantity)
        movements = StockMovement.where(item_id: item.id)

        item.update_columns(
          current_quantity: current_quantity,
          # 集計窓の下限に使う。その品目の最初の在庫イベント日 (最新日ではない)
          tracking_started_on: movements.minimum(:occurred_on),
          # 予測のアンカー。使用と棚卸のマイナス差分だけを数え、廃棄は含まない
          last_consumed_on: movements.consumption.maximum(:occurred_on)
        )
      end
  end
end
