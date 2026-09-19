module Stock
  # 記録の削除 -> 再計算 (docs/spec/01-domain-model.md 5 節)。
  # Phase 8 で扱うのは使用記録 (UsageRecord)。分割された movement がすべて消え、
  # 在庫が戻り、補填で作った調整ロットも一緒に片づく。
  # 戻り値は UsageRecord。削除できたかは usage_record.destroyed? で判断する。
  class DeleteMovement
    def self.call(usage_record)
      new(usage_record).call
    end

    def initialize(usage_record)
      @usage_record = usage_record
      @item = usage_record.item
    end

    def call
      ApplicationRecord.transaction do
        item.lock!
        # ロックの前に読んだ値で判断しない (ロック待ちの間に編集されることがある)
        usage_record.reload
        UsageMovements.discard!(usage_record)
        raise ActiveRecord::Rollback unless usage_record.destroy

        Recalculator.call(item)
      end
      usage_record
    end

    private
      attr_reader :usage_record, :item
  end
end
