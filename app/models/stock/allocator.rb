module Stock
  # FEFO の引き当て (docs/spec/01-domain-model.md 5 節)。
  #
  #   Stock::Allocator.call(item:, quantity:, user:, on:, preferred_lot_id:, fallback_lot_ids:)
  #     -> Result(allocations: [[lot, qty], ...], shortage:, compensating_lot:,
  #               preferred_lot_unavailable:)
  #
  # 順番は「期限が近い順 → 期限なし → 期限切れは最後」「同じ期限なら購入が古い順」(Lot.fefo)。
  # 期限切れを先に引くと、期限切れを除いて数える要購入判定の在庫 q が減らず
  # 「使ったのに減らない」状態になるので最後に回す。
  #
  # **副作用**: 在庫記録が足りないときは `kind: adjustment` のロットを作って不足分を補う
  # (設計原則 3: 記録は必ず成功させる)。補填の入庫 movement は `usage_record_id` を
  # 持たせる必要があるので呼び出し側 (Stock::UsageMovements) が作る。
  #
  # `compensate: false` にすると補填しない。棚卸と廃棄は「実物がこれだけだった」という
  # 記録なので、足りない分を作ってはいけない (不足は shortage で返るので呼び出し側が決める)。
  #
  # `expired_first: true` にすると期限切れロットを**先に**引く。廃棄は古いものから捨てるので
  # 使用 (FEFO・期限切れは最後) とは順序が逆になる。
  #
  # `on:` は使用日 (補填の調整ロットの `acquired_on` になる)。期限切れかどうかは
  # 「今日」で判断する (要購入判定の在庫 q と同じ基準にするため)。
  #
  # 引き当ての対象は必ず item.lock! の「あと」に読む。ロックの前に読んだ残数で引き当てると、
  # ロック待ちの間に入った別の記録を取りこぼす。
  class Allocator
    Result = Struct.new(:allocations, :shortage, :compensating_lot, :preferred_lot_unavailable,
      keyword_init: true)

    def self.call(item:, quantity:, user:, on: Date.current, preferred_lot_id: nil,
                  fallback_lot_ids: [], compensate: true, expired_first: false)
      new(item: item, quantity: quantity, user: user, on: on,
        preferred_lot_id: preferred_lot_id, fallback_lot_ids: fallback_lot_ids,
        compensate: compensate, expired_first: expired_first).call
    end

    def initialize(item:, quantity:, user:, on:, preferred_lot_id:, fallback_lot_ids:,
                   compensate: true, expired_first: false)
      @item = item
      @quantity = quantity
      @user = user
      @on = on
      @preferred_lot_id = preferred_lot_id
      @fallback_lot_ids = fallback_lot_ids
      @compensate = compensate
      @expired_first = expired_first
    end

    def call
      allocations = []
      remaining = quantity
      lots = candidate_lots

      lots.each do |lot|
        break unless remaining.positive?

        take = [ lot.remaining_quantity, remaining ].min
        next unless take.positive?

        allocations << [ lot, take ]
        remaining -= take
      end

      compensating_lot = create_compensating_lot(remaining) if remaining.positive? && compensate
      allocations << [ compensating_lot, remaining ] if compensating_lot

      Result.new(allocations: allocations, shortage: remaining, compensating_lot: compensating_lot,
        preferred_lot_unavailable: preferred_lot_unavailable?(lots))
    end

    private
      attr_reader :item, :quantity, :user, :on, :preferred_lot_id, :fallback_lot_ids,
        :compensate, :expired_first

      # ロックの後に読む。手動で選ばれたロット (preferred_lot_id) と、編集前に引いていた
      # ロット (fallback_lot_ids) を先頭に置き、残りは FEFO で続ける。
      # fallback を優先しないと、メモを直しただけで別のロットから引き直されてしまう
      def candidate_lots
        @candidate_lots ||= begin
          available = item.lots.available
          lots = (expired_first ? available.expired_first : available.fefo).to_a
          preferred = [ preferred_lot_id, *fallback_lot_ids ].compact.uniq
            .filter_map { |id| lots.find { |lot| lot.id == id } }

          preferred + (lots - preferred)
        end
      end

      # 手動で指定されたロットが、フォームを開いている間に使い切られていた場合。
      # 記録自体は成功させる (設計原則 3) が、黙って別のロットから引くと気づけない
      def preferred_lot_unavailable?(lots)
        preferred_lot_id.present? && lots.none? { |lot| lot.id == preferred_lot_id }
      end

      # 在庫記録の不足分。期限は入れない (FEFO で最後に引かれるので安全)。
      # 価格も入れない (「最近の単価」の平均を歪めない)
      def create_compensating_lot(shortage)
        item.lots.create!(kind: :adjustment, acquired_on: on, initial_quantity: shortage,
          remaining_quantity: 0, user: user)
      end
  end
end
