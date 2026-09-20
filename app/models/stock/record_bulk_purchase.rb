module Stock
  # 買い物リストのチェック済み行から、複数品目の購入を **1 トランザクションで** 記録する
  # (docs/spec/03-screens.md 画面 5b)。
  #
  # - 1 件でも保存できなければ全体をロールバックする (Lot だけ・movement だけを残さない)
  # - 品目は id の昇順でロックする (デッドロック防止。docs/spec/01-domain-model.md 5 節)
  # - 対象の永続行はロックの後に読み直し、他の人が先に記録していたら :stale を返す
  class RecordBulkPurchase
    # status: :ok (記録した) / :stale (行が消えていた) / :invalid (入力エラー)
    Result = Data.define(:status, :lot_count, :free_text_count) do
      def ok?
        status == :ok
      end

      def stale?
        status == :stale
      end
    end

    def self.call(purchase:, user:, today: Date.current)
      new(purchase: purchase, user: user, today: today).call
    end

    def initialize(purchase:, user:, today:)
      @purchase = purchase
      @user = user
      @today = today
      @status = :ok
      @free_text_count = 0
    end

    def call
      ApplicationRecord.transaction do
        rows = lock_rows

        if stale?(rows)
          @status = :stale
          raise ActiveRecord::Rollback
        end

        unless record_lots
          @status = :invalid
          raise ActiveRecord::Rollback
        end

        remove_rows(rows)
      end

      Result.new(status: @status, lot_count: (@status == :ok ? purchase.lines.size : 0),
        free_text_count: @free_text_count)
    end

    private
      attr_reader :purchase, :user, :today

      # ロックしてから読み直す。フォームを開いている間に他の人がまとめ購入を済ませていると、
      # ここで行が消えている
      def lock_rows
        ShoppingListItem.where(id: purchase.record_ids).order(:id).lock.to_a
      end

      def stale?(rows)
        rows.size != purchase.record_ids.size || rows.any? { |row| !row.checked? }
      end

      def record_lots
        # 品目の id 昇順でロックする (RecordPurchase が item.lock! する)
        purchase.lines.sort_by { |line| line.item.id }.each do |line|
          RecordPurchase.call!(item: line.item, user: user, attributes: line.lot_attributes)
        rescue ActiveRecord::RecordInvalid => e
          # 入庫の movement が保存できなかった場合は Lot ではない。
          # そのまま行に戻すと、入力を描き直すビューが別のモデルを受け取って 500 になる
          raise unless e.record.is_a?(Lot)

          # エラーの付いた Lot をそのまま行に戻し、入力を保ったまま描き直せるようにする
          line.lot = e.record
          return false
        end

        true
      end

      # 買った行は消す。自由入力は在庫に記録できないが「買った」ものなのでまとめて消すが、
      # **消すのはフォームに出ていた行だけ** (purchase.free_text_ids)。
      # 開いている間に他の人がチェックした自由入力まで消すと、見ていないものが黙って消える。
      #
      # 品目の行は settle_after_purchase! で片づける。チェックだけでなく数量の上書きや
      # 手動追加の印も消すので、次に urgent に戻ったときに古い上書きが復活しない。
      # ついでに、見えなくなった古い行 (アーカイブ済み品目・期限切れのスヌーズ) も片づける
      def remove_rows(rows)
        @free_text_count = ShoppingListItem.free_text_entries.checked
          .where(id: purchase.free_text_ids).delete_all
        ShoppingListItem.where(id: rows.map(&:id)).delete_all
        purchase.lines.each { |line| ShoppingListItem.settle_after_purchase!(line.item) }
        ShoppingListItem.purge_stale!(today)
      end
  end
end
