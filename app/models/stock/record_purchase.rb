module Stock
  # Lot + StockMovement(purchase) を 1 トランザクションで作る
  # (docs/spec/01-domain-model.md 5 節)。
  # すべての入庫がロットを作るので、初期在庫 (kind: initial) も同じ経路を通る。
  # 戻り値は Lot。保存できなかったときは errors が入った未保存の Lot が返る。
  class RecordPurchase
    def self.call(item:, user:, attributes:)
      new(item: item, user: user, attributes: attributes).call
    end

    # 入れ子で呼ぶとき用 (docs/spec/01-domain-model.md 5 節)。
    # 内側の `raise ActiveRecord::Rollback` は外側のトランザクションに届かず、
    # 「1 件だけ保存できなかったのに全体はコミットされる」が起きるので、
    # 保存できなかったことを例外で外に伝える (まとめ購入が使う)
    def self.call!(item:, user:, attributes:)
      call(item: item, user: user, attributes: attributes).tap do |lot|
        raise ActiveRecord::RecordInvalid, lot unless lot.persisted?
      end
    end

    def initialize(item:, user:, attributes:)
      @item = item
      @user = user
      @lot = Lot.new(attributes)
      # 品目・記録者・キャッシュ列は入力から受け取らない
      # (attributes に item_id があっても別の品目には付け替えさせない)
      @lot.item = item
      @lot.user = user
      @lot.remaining_quantity = 0
      @lot.depleted_at = nil
    end

    def call
      ApplicationRecord.transaction do
        item.lock!
        raise ActiveRecord::Rollback unless lot.save

        create_inbound_movement
        Recalculator.call(item)
        lot.reload
      end
      lot
    end

    private
      attr_reader :item, :user, :lot

      def create_inbound_movement
        lot.stock_movements.create!(
          item: item, user: user, kind: :purchase,
          quantity: lot.initial_quantity, occurred_on: lot.acquired_on
        )
      end
  end
end
