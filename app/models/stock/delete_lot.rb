module Stock
  # ロット (購入記録) の削除。紐づく movement も消えて在庫が元に戻る。
  # 出庫の記録が紐づくロットは Lot の before_destroy が止める
  # (docs/spec/01-domain-model.md 3 節)。
  # 戻り値は Lot。削除できたかは lot.destroyed? で判断する。
  class DeleteLot
    def self.call(lot)
      new(lot).call
    end

    def initialize(lot)
      @lot = lot
      @item = lot.item
    end

    def call
      ApplicationRecord.transaction do
        item.lock!
        # ロックの前に読んだ値で判断しない (ロック待ちの間に使用が記録されることがある)
        lot.reload
        raise ActiveRecord::Rollback unless lot.destroy

        Recalculator.call(item)
      end
      lot
    end

    private
      attr_reader :lot, :item
  end
end
