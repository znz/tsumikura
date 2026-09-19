module Stock
  # 棚卸の確定 (docs/spec/01-domain-model.md 判断 3)。
  # 下書きの間は在庫にいっさい触れず、ここで初めて台帳を動かす。
  #
  #   - 確定時点の記録在庫を expected_quantity に取り直す
  #     (下書きを作ってから在庫が変わっていても、差分は「今の記録在庫」との差になる)
  #   - マイナス差分は FEFO で引く (期限切れロットは最後)。補填はしない
  #     ("実物がこれだけだった" という記録なので、足りない分を作ってはいけない)
  #   - 合計で数えた明細のプラス差分は kind: adjustment の新規ロット
  #     (期限 NULL・価格 NULL) を作って足す (「知らない期限」を勝手に主張しないため)
  #   - **ロット別に数えた明細のプラス差分は、そのロットに正の adjustment を足す。**
  #     ユーザーがロットを特定しているので期限を主張することにならず、新規ロットを
  #     作ると次の棚卸で同じ実物が 2 行に見えて数えるたびに水増しされてしまう
  #   - 差分 0 は movement を作らない。実数が未入力の明細はスキップする
  #
  # 複数の品目を触るので、デッドロック防止に **id の昇順**でロックする。
  # 全体を 1 トランザクションで包み、途中で失敗したら movement も finalized_at も残さない。
  class FinalizeStockTake
    # 2 台で同時に確定ボタンを押された。ロックの後に finalized_at を見て気づく
    class AlreadyFinalized < StandardError; end
    # 記録在庫を引き当てきれなかった。差分は記録在庫との差なので定義上起こらず、
    # 起きたならキャッシュと台帳がずれている (rake stock:verify の出番)
    class LedgerInconsistent < StandardError; end
    # 1 件も数えていない棚卸。在庫は動かないのに棚卸日だけが進み、以降の記録すべてに
    # 「直近の棚卸日より前です」の警告が出てしまうので確定させない
    class NothingCounted < StandardError; end

    def self.call(stock_take, user:)
      new(stock_take, user: user).call
    end

    def initialize(stock_take, user:)
      @stock_take = stock_take
      @user = user
    end

    def call
      ApplicationRecord.transaction do
        # ヘッダも行ロックする。二重確定の判定はロックの「あと」でなければ意味がない
        stock_take.lock!
        raise AlreadyFinalized, "棚卸 ##{stock_take.id} はすでに確定しています" if stock_take.finalized?

        items = locked_items
        raise NothingCounted, "棚卸 ##{stock_take.id} はまだ 1 件も数えていません" if items.empty?

        items.each { |item| apply_item(item) }
        stock_take.update!(finalized_at: Time.current)
      end
      stock_take
    end

    private
      attr_reader :stock_take, :user

      # デッドロック防止に id の昇順でロックする。
      # lock! は行ロックと同時に読み直すので、ここから先は確定時点の値で判断できる
      def locked_items
        ids = stock_take.stock_take_entries.counted.distinct.pluck(:item_id).sort

        ids.map { |id| Item.lock.find(id) }
      end

      def apply_item(item)
        entries(item).each { |entry| apply_entry(item, entry) }
      end

      # 合計の明細 (lot_id が nil) を先に、そのあとロット別の明細。
      # 画面は両方を作らせないが、DB に両方あったらロット別 (より細かいほう) を採り、
      # 合計の明細は無視する (二重に数えない。docs/spec/01-domain-model.md 判断 3)
      def entries(item)
        all = stock_take.stock_take_entries.counted.where(item_id: item.id).ordered.to_a
        by_lot = all.select { |entry| entry.lot_id.present? }

        by_lot.presence || all
      end

      def apply_entry(item, entry)
        # ロックの後に読み直す (下書きを作ってからの変化に追随する)
        lot = Lot.find(entry.lot_id) if entry.lot_id.present?
        entry.update!(expected_quantity: lot ? lot.remaining_quantity : item.current_quantity)
        return if entry.difference.zero?

        if entry.difference.negative?
          withdraw(item, entry, lot, -entry.difference)
        else
          deposit(item, entry, lot, entry.difference)
        end

        # 同じ品目に明細が複数あるので、次の明細が「今の記録在庫」を見られるよう毎回直す
        Recalculator.call(item)
      end

      # マイナス差分。ロット別に数えた明細はそのロットから、合計の明細は FEFO で引く
      def withdraw(item, entry, lot, quantity)
        allocations =
          if lot
            [ [ lot, quantity ] ]
          else
            allocate(item, quantity)
          end

        allocations.each do |target_lot, taken|
          raise LedgerInconsistent, ledger_message(item) if target_lot.remaining_quantity < taken

          create_movement(item, entry, target_lot, -taken)
        end
      end

      def allocate(item, quantity)
        result = Allocator.call(item: item, quantity: quantity, user: user,
          on: stock_take.counted_on, compensate: false)
        raise LedgerInconsistent, ledger_message(item) if result.shortage.positive?

        result.allocations
      end

      # プラス差分。ロット別に数えたならそのロットに足し、合計で数えたなら
      # 新しい調整ロットを作る (期限も価格も分からないので入れない。
      # 期限 NULL は FEFO で最後に引かれるので安全)
      def deposit(item, entry, lot, quantity)
        target = lot || item.lots.create!(kind: :adjustment, acquired_on: stock_take.counted_on,
          initial_quantity: quantity, remaining_quantity: 0, user: user)

        create_movement(item, entry, target, quantity)
      end

      # 棚卸で動いた分は必ず明細に紐づける (差分と movements の合計が一致していることを
      # rake stock:verify が見張る)。使用記録には紐づけない
      def create_movement(item, entry, lot, quantity)
        lot.stock_movements.create!(
          item: item, user: user, kind: :adjustment, quantity: quantity,
          occurred_on: stock_take.counted_on, stock_take_entry: entry
        )
      end

      def ledger_message(item)
        "品目 ##{item.id}「#{item.name}」の記録在庫を引き当てきれませんでした " \
          "(bin/rails stock:verify で確認してください)"
      end
  end
end
