module Stock
  # 使用記録の編集 (数量・日付・用途・引き当て先ロット)。
  # movement は直さず作り直す。FEFO の分割は数量や日付で変わるうえ、
  # 補填の調整ロットも付いたり消えたりするので、差分更新では合わせきれない
  # (docs/spec/01-domain-model.md 5 節)。
  # 戻り値は UsageRecord。保存できなかったときは errors が入った (入力を保った) UsageRecord。
  class ReviseUsage
    def self.call(usage_record, attributes)
      new(usage_record, attributes).call
    end

    def self.call!(usage_record, attributes)
      new(usage_record, attributes).call!
    end

    def initialize(usage_record, attributes)
      @usage_record = usage_record
      @attributes = attributes
      @item = usage_record.item
    end

    def call
      ApplicationRecord.transaction do
        item.lock!
        # ロックの前に読んだ値で判断しない (古い画面からの保存で台帳とずれるのを防ぐ)
        usage_record.reload
        usage_record.assign_attributes(attributes)
        restore_protected_attributes
        raise ActiveRecord::Rollback unless usage_record.save

        rebuild_movements
      end
      usage_record
    end

    def call!
      call
      raise ActiveRecord::RecordInvalid, usage_record if usage_record.errors.any?

      usage_record
    end

    private
      attr_reader :usage_record, :attributes, :item

      # 品目と記録者は編集で動かさない (フォームから来ても無視する)
      def restore_protected_attributes
        usage_record.item_id = usage_record.item_id_in_database
        usage_record.user_id = usage_record.user_id_in_database
      end

      # 先に古い movement を消して在庫を戻し、再計算してから引き当て直す。
      # 戻す前に引き当てると、自分がさっき引いた分を二重に引いてしまう。
      # 引き直しは元のロットを優先する (メモや用途だけの編集で、ロット別の残数や
      # 期限切れかどうかが変わってしまわないように)。
      # 消えた補填の調整ロットの id は候補に見つからないので無視される
      def rebuild_movements
        previous_lot_ids = UsageMovements.allocated_lot_ids(usage_record)

        UsageMovements.discard!(usage_record)
        Recalculator.call(item)

        UsageMovements.write!(usage_record, fallback_lot_ids: previous_lot_ids)
        Recalculator.call(item)
      end
  end
end
