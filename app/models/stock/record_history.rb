module Stock
  # 品目 1 件の記録 (使用・購入・廃棄・棚卸の調整) を 1 本の時系列にまとめて返す。
  #
  # 品目詳細の「最近の記録」(10 件。ItemDetails) と全履歴 (全件。Items::RecordsController) が
  # **同じ並びと同じ除外条件**を使うためにここに置く。片方にだけ出る記録があると、
  # 「詳細には出ているのに履歴に無い」という食い違いになる。
  # 記録は 3 つのテーブルに分かれていて 1 本の SQL で並べられないので、並べ替えと件数の
  # 切り出しは Ruby 側で行う (家庭用なので 1 品目の記録は多くても数千件)。
  #
  # ダッシュボードの「最近の記録」は全品目横断で品目名も出す (別の includes が要る) ので、
  # そちらは DashboardSummary に置いたままにする。
  class RecordHistory
    # limit: nil なら全件。limit を渡すと新しい順にその件数だけ返す
    def self.call(item, limit: nil)
      new(item, limit: limit).call
    end

    def initialize(item, limit: nil)
      @item = item
      @limit = limit
    end

    # 新しい順。同じ日なら後から記録したものを新しいとみなす
    # (各テーブルの recent_first スコープと同じ規則)
    def call
      records = (usages + purchases + movements)
        .sort_by { |record| [ record.recorded_on, record.created_at ] }
        .reverse

      limit ? records.take(limit) : records
    end

    private
      attr_reader :item, :limit

      # 行ごとに用途・店舗・棚卸を出すので、includes しないと記録の数だけクエリが増える
      def usages
        recent(item.usage_records.includes(:item_purpose))
      end

      # 在庫不足の補填で作られた調整ロットはユーザーの操作ではないので出さない
      # (補填したことはトーストで伝えている)
      def purchases
        recent(item.lots.recordable.includes(:store))
      end

      # 廃棄と、棚卸の確定で入った調整 (明細に紐づく行だけ。補填の調整は出さない)
      def movements
        recent(item.stock_movements.kind_disposal
          .or(item.stock_movements.recorded_adjustments)
          .includes(:stock_take_entry))
      end

      # 混ぜたあとに limit 件へ切るので、各テーブルからは limit 件ずつ引けば足りる
      # (どれか 1 つのテーブルの記録だけで limit 件が埋まる場合が最悪ケース)
      def recent(relation)
        relation = relation.recent_first
        relation = relation.limit(limit) if limit

        relation.to_a
      end
  end
end
