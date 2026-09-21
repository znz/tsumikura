module Stock
  # 使用記録 1 件に紐づく stock_movements の作成と片づけ。
  # Stock::RecordUsage / Stock::ReviseUsage / Stock::DeleteMovement が共有する
  # (docs/spec/01-domain-model.md 5 節)。必ず item.lock! の中から呼ぶこと。
  class UsageMovements
    # 引き当てて movement を作る。引き当ての結果は usage_record の
    # compensated_quantity / preferred_lot_unavailable に載せる (戻り値は補填した数)。
    # fallback_lot_ids は編集前に引いていたロット (指定が無ければそこから引き直す)
    def self.write!(usage_record, fallback_lot_ids: [])
      new(usage_record).write!(fallback_lot_ids: fallback_lot_ids)
    end

    # 紐づく movement を消し、空になった補填の調整ロットも片づける
    def self.discard!(usage_record)
      new(usage_record).discard!
    end

    # 引き当てているロットの id (編集で引き直すときの優先順)
    def self.allocated_lot_ids(usage_record)
      # 引き当てた順 (挿入順)。主キーは UUIDv7 なので created_at を先に見る
      usage_record.stock_movements.where(quantity: ...0).order(:created_at, :id).pluck(:lot_id)
    end

    def initialize(usage_record)
      @usage_record = usage_record
      @item = usage_record.item
      @user = usage_record.user
    end

    def write!(fallback_lot_ids: [])
      result = Allocator.call(item: item, quantity: usage_record.quantity, user: user,
        on: usage_record.used_on, preferred_lot_id: usage_record.selected_lot_id,
        fallback_lot_ids: fallback_lot_ids)

      create_compensating_movement(result)
      result.allocations.each { |lot, quantity| create_usage_movement(lot, quantity) }

      usage_record.compensated_quantity = result.shortage
      usage_record.preferred_lot_unavailable = result.preferred_lot_unavailable
      result.shortage
    end

    def discard!
      lots = usage_record.stock_movements.includes(:lot).map(&:lot).uniq
      usage_record.stock_movements.destroy_all

      # 補填で作った調整ロットは、movement が無くなると「実在しない在庫の空き箱」になる。
      # 棚卸のプラス差分で作られたロットには stock_take_entry の入庫が残るので消えない。
      # 消せないロットは台帳が壊れている合図なので、黙って残さず例外にする
      lots.each do |lot|
        lot.destroy! if lot.kind_adjustment? && lot.stock_movements.reload.empty?
      end
    end

    private
      attr_reader :usage_record, :item, :user

      # 在庫不足の補填 (正の adjustment)。usage_record_id を持たせるのは、
      # 記録の編集・削除でこの入庫ごと片づけるため
      def create_compensating_movement(result)
        return if result.compensating_lot.nil?

        result.compensating_lot.stock_movements.create!(
          item: item, user: user, kind: :adjustment, quantity: result.shortage,
          occurred_on: usage_record.used_on, usage_record: usage_record
        )
      end

      def create_usage_movement(lot, quantity)
        lot.stock_movements.create!(
          item: item, user: user, kind: :usage, quantity: -quantity,
          occurred_on: usage_record.used_on, usage_record: usage_record
        )
      end
  end
end
