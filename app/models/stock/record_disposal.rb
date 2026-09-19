module Stock
  # 廃棄の記録 (docs/spec/01-domain-model.md 5 節)。
  # kind: disposal の StockMovement を作るだけで、ヘッダのテーブルは持たない。
  #
  # 引き当ては「ロットを指定すればそのロットから、指定が無ければ 期限切れ → FEFO の順」。
  # 使用 (FEFO・期限切れは最後) と逆なのは、捨てるのは古いものからだから。
  # **補填はしない** (`compensate: false`)。廃棄は「実物を捨てた」記録なので、
  # 在庫記録を超える廃棄は作らずに検証エラー (422) にする。
  #
  # 戻り値は Disposal。成功したかは disposal.movements の有無で判断する。
  class RecordDisposal
    def self.call(item:, user:, attributes:)
      new(item: item, user: user, attributes: attributes).call
    end

    def initialize(item:, user:, attributes:)
      @item = item
      @user = user
      @disposal = Disposal.new(attributes)
      @disposal.item = item
      @disposal.user = user
    end

    def call
      ApplicationRecord.transaction do
        item.lock!
        raise ActiveRecord::Rollback unless disposal.valid?

        allocations = allocations()
        raise ActiveRecord::Rollback if allocations.nil?

        disposal.movements = allocations.map { |lot, quantity| create_movement(lot, quantity) }
        Recalculator.call(item)
      end
      disposal
    end

    private
      attr_reader :item, :user, :disposal

      # ロックの後に読み直す (ロック待ちの間に使い切られていることがある)
      def allocations
        disposal.lot_id.present? ? from_selected_lot : from_stock
      end

      # 指定されたロットからだけ引く。足りないぶんを黙って別のロットから引くと、
      # 「このロットを捨てた」という記録が別のロットの残数を減らしてしまう
      def from_selected_lot
        lot = item.lots.find_by(id: disposal.lot_id)
        return lot_gone if lot.nil?
        return insufficient_lot(lot) if lot.remaining_quantity < disposal.quantity

        [ [ lot, disposal.quantity ] ]
      end

      def from_stock
        result = Allocator.call(item: item, quantity: disposal.quantity, user: user,
          on: disposal.occurred_on, compensate: false, expired_first: true)
        return insufficient_stock if result.shortage.positive?

        result.allocations
      end

      def lot_gone
        disposal.errors.add(:lot_id, :invalid)
        nil
      end

      def insufficient_lot(lot)
        disposal.errors.add(:quantity, :exceeds_lot, remaining: lot.remaining_quantity)
        nil
      end

      def insufficient_stock
        disposal.errors.add(:quantity, :exceeds_stock, available: item.current_quantity)
        nil
      end

      def create_movement(lot, quantity)
        lot.stock_movements.create!(
          item: item, user: user, kind: :disposal, quantity: -quantity,
          occurred_on: disposal.occurred_on, disposal_reason: disposal.disposal_reason,
          note: disposal.note
        )
      end
  end
end
