module Forecast
  # 予測の入力値 (docs/spec/02-forecast.md 2〜3 節) を台帳から集める AR クエリ担当。
  #
  # 1 品目版が SnapshotBuilder、一覧用が BatchForecaster で、**集計の式はここ 1 か所だけ**に置く
  # (2 か所に書くと「一覧のバッジと詳細の予測が違う」という最悪のバグになる)。
  # 品目が N 件でも発行するクエリは 4 本に固定する:
  #
  #   1. 品目ごとの「直近 window_events 件目の消費イベント日」(ウィンドウ関数)
  #   2. 期限切れを除いた在庫 q
  #   3. 品目ごとの窓での consumed / event_count (VALUES との JOIN)
  #   4. 品目ごとの窓での u (1 回あたりの使用数の中央値)
  #
  # 窓の開始日は品目ごとに違う (仕様 3 節) ので、1 の結果から Ruby (Forecast::Window) で
  # 決めてから 3・4 を引く。2 段階になるが、どちらの段でも品目の数だけクエリは増えない。
  class Aggregator
    def initialize(items, today: Date.current)
      @items = Array(items)
      @today = today
    end

    # { item_id => Forecast::Snapshot }
    def snapshots
      @snapshots ||= items.to_h { |item| [ item.id, snapshot_for(item) ] }
    end

    private
      attr_reader :items, :today

      # 消費イベントが無い品目は consumed も event_count も 0 (窓の中に 1 行も無い)
      NO_CONSUMPTION = [ 0, 0 ].freeze
      private_constant :NO_CONSUMPTION

      def item_ids
        @item_ids ||= items.map(&:id)
      end

      def snapshot_for(item)
        window = windows.fetch(item.id)
        consumed, event_count = consumption_totals.fetch(item.id, NO_CONSUMPTION)

        Snapshot.new(
          quantity: quantities.fetch(item.id, 0),
          minimum_quantity: item.minimum_quantity,
          consumed: consumed,
          event_count: event_count,
          observed_days: window.observed_days,
          anchor_on: anchor_on(item),
          unit_usage: unit_usage(item),
          # AR の enum は文字列を返す。Forecast::Pace は Symbol 以外を ArgumentError にする
          mode: item.estimation_mode.to_sym,
          manual_interval_days: item.manual_interval_days,
          thresholds: thresholds_for(item),
          today: today
        )
      end

      # アンカー (仕様 2 節)。キャッシュ列を読むだけなので追加のクエリは出ない
      def anchor_on(item)
        item.last_consumed_on || item.tracking_started_on
      end

      def windows
        @windows ||= items.to_h { |item| [ item.id, window_for(item) ] }
      end

      def window_for(item)
        anchor = anchor_on(item)

        Window.for(
          today: today,
          # 起点が無いのに窓だけ消費イベント日まで伸ばすと、窓の終わり (anchor) が nil になる。
          # キャッシュがずれたときは伸ばさない (判定はどのみち unknown になる。仕様 4 節)
          nth_event_on: anchor && nth_event_dates[item.id],
          last_event_on: anchor,
          tracking_started_on: item.tracking_started_on,
          thresholds: thresholds_for(item)
        )
      end

      # 品目ごとの閾値の上書き (仕様 6 節)。未設定 (nil) の列は既定値を残す
      def thresholds_for(item)
        @thresholds_for ||= {}
        @thresholds_for[item.id] ||= Thresholds.default.with(**{
          soon_days: item.soon_threshold_days,
          urgent_days: item.urgent_threshold_days
        }.compact)
      end

      # u は 1 回あたりの使用数の中央値 (仕様 2 節)。小数は四捨五入し、最低 1。
      # 使用記録が無ければ 1 (棚卸のマイナス差分は usage_records に無いので u には入らない)
      def unit_usage(item)
        median = usage_medians[item.id]
        return 1 if median.nil?

        [ median.round, 1 ].max
      end

      # --- ここから下がクエリ ---

      # (1) 直近 window_events 件目の消費イベント日。件数が足りなければ最古の消費イベント日
      # (= 直近 N 件の最小値なので、どちらも同じ式で取れる)。
      # DENSE_RANK で順位を付けるので、同じ日の複数行 (FEFO の分割・棚卸の複数 movement) は
      # まとめて 1 件と数えられる (仕様 2 節)。
      # window_* の閾値は品目ごとに上書きできない (上書きできるのは soon / urgent だけ) ので、
      # ここだけは既定値を使ってよい
      def nth_event_dates
        @nth_event_dates ||= item_ids.empty? ? {} : query_nth_event_dates
      end

      def query_nth_event_dates
        # 窓の中の集計 (3)(4) は today で打ち切っているので、ここだけ上限が無いと
        # 未来日の today を渡したときに基準がそろわない。
        # なお anchor はキャッシュ列なので上限を掛けられない。**today は Date.current 以降
        # (日数を進めたシミュレーション) だけをサポートする** (仕様 14 節)
        ranked = StockMovement.consumption.where(item_id: item_ids, occurred_on: ..today)
          .select(:item_id, :occurred_on)
          .select(Arel.sql("DENSE_RANK() OVER (PARTITION BY item_id ORDER BY occurred_on DESC) AS event_rank"))

        StockMovement
          .with(ranked_events: ranked)
          .from("ranked_events")
          .where("ranked_events.event_rank <= ?", Thresholds.default.window_events)
          .group("ranked_events.item_id")
          .pluck(Arel.sql("ranked_events.item_id"), Arel.sql("MIN(ranked_events.occurred_on)"))
          .to_h
      end

      # (2) 在庫 q。期限切れロットの残数は除く (仕様 2 節)。
      # 全ロットが期限切れの品目はキーごと落ちるので 0 になる
      def quantities
        @quantities ||= item_ids.empty? ? {} : query_quantities
      end

      def query_quantities
        Lot.available.unexpired(today).where(item_id: item_ids)
          .group(:item_id).sum(:remaining_quantity)
      end

      # (3) 窓の中の消費量と消費イベント数。
      # consumed は半開区間 (window_start, today]、event_count は閉区間 [window_start, today]
      # の「消費のあった日」の数 (仕様 3 節)。JOIN は閉区間で取り、consumed だけ CASE で外す
      def consumption_totals
        @consumption_totals ||= windows.empty? ? {} : query_consumption_totals
      end

      def query_consumption_totals
        StockMovement.consumption
          .joins(windows_join("stock_movements"))
          .where("stock_movements.occurred_on BETWEEN item_windows.window_start AND ?", today)
          .group("item_windows.item_id")
          .pluck(
            Arel.sql("item_windows.item_id"),
            # 消費の行は必ず負なので、符号を反転して絶対値の合計にする
            Arel.sql("COALESCE(SUM(CASE WHEN stock_movements.occurred_on > item_windows.window_start " \
                     "THEN -stock_movements.quantity ELSE 0 END), 0)"),
            Arel.sql("COUNT(DISTINCT stock_movements.occurred_on)")
          )
          .to_h { |item_id, consumed, event_count| [ item_id, [ consumed, event_count ] ] }
      end

      # (4) u の中央値。消費量 (stock_movements) とは別のテーブルから数える
      # (docs/spec/01-domain-model.md 5 節の申し送り)。半開区間 (window_start, today]
      def usage_medians
        @usage_medians ||= windows.empty? ? {} : query_usage_medians
      end

      def query_usage_medians
        UsageRecord
          .joins(windows_join("usage_records"))
          .where("usage_records.used_on > item_windows.window_start AND usage_records.used_on <= ?", today)
          .group("item_windows.item_id")
          .pluck(
            Arel.sql("item_windows.item_id"),
            Arel.sql("PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY usage_records.quantity::double precision)")
          )
          .to_h
      end

      # 品目ごとに窓の開始日が違うので、(item_id, window_start) の表を VALUES で作って JOIN する。
      # これで「品目ごとに 1 クエリ」を避けられる。値は必ず束縛する (渡すのは id と日付だけだが、
      # 文字列連結で SQL を組み立てない)
      def windows_join(table)
        rows = Array.new(windows.size, "(?::uuid, ?::date)").join(", ")
        binds = windows.flat_map { |item_id, window| [ item_id, window.start_on ] }

        ActiveRecord::Base.sanitize_sql_array([
          "INNER JOIN (VALUES #{rows}) AS item_windows (item_id, window_start) " \
          "ON item_windows.item_id = #{table}.item_id", *binds
        ])
      end
  end
end
