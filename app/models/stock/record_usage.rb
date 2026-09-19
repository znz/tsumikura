module Stock
  # UsageRecord + StockMovement(s) を 1 トランザクションで作る
  # (docs/spec/01-domain-model.md 5 節)。
  # 在庫記録が足りなくても補填して必ず成功する (設計原則 3)。補填した数は
  # usage_record.compensated_quantity で受け取れる。
  # 戻り値は UsageRecord。保存できなかったときは errors が入った未保存の UsageRecord が返る。
  class RecordUsage
    def self.call(item:, user:, attributes:)
      new(item: item, user: user, attributes: attributes).call
    end

    # 入れ子で呼ぶとき用。内側の ActiveRecord::Rollback は内側の transaction に
    # 握りつぶされ、外側はコミットされてしまうので、例外で外まで知らせる
    def self.call!(item:, user:, attributes:)
      new(item: item, user: user, attributes: attributes).call!
    end

    def initialize(item:, user:, attributes:)
      @item = item
      @user = user
      @usage_record = UsageRecord.new(attributes)
      # 品目・記録者は入力から受け取らない (attributes に item_id があっても付け替えさせない)
      @usage_record.item = item
      @usage_record.user = user
    end

    def call
      ApplicationRecord.transaction do
        item.lock!
        raise ActiveRecord::Rollback unless usage_record.save

        UsageMovements.write!(usage_record)
        Recalculator.call(item)
      end
      usage_record
    end

    def call!
      call
      raise ActiveRecord::RecordInvalid, usage_record unless usage_record.persisted?

      usage_record
    end

    private
      attr_reader :item, :user, :usage_record
  end
end
