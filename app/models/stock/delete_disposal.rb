module Stock
  # 廃棄の取り消し (docs/spec/01-domain-model.md 5 節)。
  # 使用記録の削除 (Stock::DeleteMovement) と違い、廃棄はヘッダを持たず movement 1 行が
  # 記録そのものなので、引数の型で分岐させずサービスを分ける
  # (Phase 8 からの申し送り)。
  # 戻り値は StockMovement。削除できたかは movement.destroyed? で判断する。
  class DeleteDisposal
    def self.call(movement)
      new(movement).call
    end

    def initialize(movement)
      @movement = movement
      @item = movement.item
    end

    def call
      ApplicationRecord.transaction do
        item.lock!
        # ロックの前に読んだ値で判断しない (ロック待ちの間に消されることがある)
        movement.reload
        raise ActiveRecord::Rollback unless movement.destroy

        Recalculator.call(item)
      end
      movement
    end

    private
      attr_reader :movement, :item
  end
end
