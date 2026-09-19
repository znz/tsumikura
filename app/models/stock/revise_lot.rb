module Stock
  # ロット (購入記録) の編集。入庫の movement を実際の数量・日付に合わせ直し、
  # キャッシュを再計算する。編集後の残数が負になる変更は Lot の検証で弾かれる
  # (docs/spec/01-domain-model.md 3 節)。
  # 戻り値は Lot。保存できなかったときは errors が入った (入力を保った) Lot が返る。
  class ReviseLot
    # 入庫の movement が無いロットは台帳が壊れている。黙って直さず気づけるようにする
    class InboundMovementMissing < StandardError; end

    def self.call(lot, attributes)
      new(lot, attributes).call
    end

    def initialize(lot, attributes)
      @lot = lot
      @attributes = attributes
      @item = lot.item
    end

    def call
      ApplicationRecord.transaction do
        item.lock!
        # ロックの前に読んだ値で判断しない (古い画面からの保存で台帳とずれるのを防ぐ)
        lot.reload
        lot.assign_attributes(attributes)
        restore_protected_attributes
        raise ActiveRecord::Rollback unless lot.save

        inbound_movement.update!(quantity: lot.initial_quantity, occurred_on: lot.acquired_on)
        Recalculator.call(item)
        lot.reload
      end
      lot
    end

    private
      attr_reader :lot, :attributes, :item

      # 由来・キャッシュ列・記録者・品目は編集で動かさない (フォームから来ても無視する)
      def restore_protected_attributes
        lot.kind = lot.kind_in_database
        lot.remaining_quantity = lot.remaining_quantity_in_database
        lot.depleted_at = lot.depleted_at_in_database
        lot.user_id = lot.user_id_in_database
        lot.item_id = lot.item_id_in_database
      end

      # 入庫の movement (購入、または棚卸のプラス差分)。数量と日付をロットに合わせる
      def inbound_movement
        lot.stock_movements.where(quantity: 1..).order(:id).first ||
          raise(InboundMovementMissing, "ロット ##{lot.id} に入庫の記録がありません")
      end
  end
end
