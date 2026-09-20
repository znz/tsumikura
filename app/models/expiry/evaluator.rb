module Expiry
  # 品目ごとの期限ステータス (docs/spec/02-forecast.md 12 節)。
  #
  # 残数が 1 以上のロットだけを対象に、ロットごとに判定して**最悪値**を品目のステータスにする。
  # 警告日数は品目ごとに上書きできる (Item#effective_expiry_warning_days)。
  # 一覧・ダッシュボードから N 件まとめて引くので、クエリは 1 本に固定する (N+1 にしない)。
  #
  # 要購入判定 (Forecast) とは独立しているが、「期限切れの残数は在庫 q から除く」という
  # 一点だけでつながっている (Forecast::Aggregator が Lot.unexpired で数える)。
  class Evaluator
    # { item_id => Expiry::Result }。
    # アーカイブ済みの品目は結果に入らない (Forecast::BatchForecaster と対称にする。
    # 片方だけが落とすと、一覧のバッジや日次ダイジェストでねじれが起きる)
    def self.call(items, today: Date.current)
      new(Array(items).reject(&:archived?), today: today).call
    end

    # 品目 1 件版 (品目詳細用)。品目詳細はアーカイブ済みでも開けるので、ここでは落とさない
    def self.for(item, today: Date.current)
      new([ item ], today: today).call.fetch(item.id)
    end

    def initialize(items, today: Date.current)
      @items = Array(items)
      @today = today
    end

    def call
      items.to_h { |item| [ item.id, result_for(item) ] }
    end

    private
      attr_reader :items, :today

      def result_for(item)
        dates = expiry_dates.fetch(item.id, [])
        warning_days = item.effective_expiry_warning_days
        statuses = dates.map { |on| Status.for(expires_on: on, today: today, warning_days: warning_days) }

        Result.new(
          status: Status.worst(statuses),
          expired_count: statuses.count(Status::EXPIRED),
          expiring_soon_count: statuses.count(Status::EXPIRING_SOON),
          nearest_expires_on: dates.min
        )
      end

      # 残数 1 以上で期限のあるロットだけを 1 クエリで引く。
      # 期限なしのロットは必ず FRESH なので、判定にも「最も近い期限」にも影響しない
      def expiry_dates
        @expiry_dates ||= items.empty? ? {} : query_expiry_dates
      end

      def query_expiry_dates
        Lot.available.where(item_id: items.map(&:id)).where.not(expires_on: nil)
          .pluck(:item_id, :expires_on)
          .group_by(&:first)
          .transform_values { |rows| rows.map(&:last) }
      end
  end
end
