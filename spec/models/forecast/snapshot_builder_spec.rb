require "rails_helper"

# 台帳 (stock_movements / usage_records) とキャッシュ列から、予測の入力値
# (docs/spec/02-forecast.md 2〜3 節) を正しく取り出せているかを見る。
# 判定そのもの (Snapshot -> Result) は Phase 3 の spec/models/forecast/calculator_spec.rb が見る。
RSpec.describe Forecast::SnapshotBuilder do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:item) { create(:item, name: "トイレットペーパー", unit: "ロール") }

  def snapshot(target = item)
    described_class.call(target.reload)
  end

  describe "消費の定義 (StockMovement.consumption)" do
    # 「使用と負の調整」の定義を Stock::Recalculator と 1 か所にそろえる
    before { stock_up(item, 500, days_ago: 200) }

    it "使用は消費量に入る" do
      record_usage(item, days_ago: 10, quantity: 3)

      expect(snapshot.consumed).to eq 3
    end

    it "棚卸のマイナス差分は消費量に入る (counted_on の 1 日に全量)" do
      count_stock(item, 480, days_ago: 10)

      expect(snapshot.consumed).to eq 20
      expect(snapshot.anchor_on).to eq Date.current - 10
    end

    it "廃棄は消費量に入らない (捨てたのは「使った」ではない)" do
      record_usage(item, days_ago: 10, quantity: 3)
      dispose(item, 7, days_ago: 5)

      expect(snapshot.consumed).to eq 3
    end

    # 廃棄でアンカーが動くと、使っていない品目の予測日が前に進んでしまう
    it "廃棄はアンカーを動かさない" do
      record_usage(item, days_ago: 10, quantity: 3)
      dispose(item, 7, days_ago: 5)

      expect(snapshot.anchor_on).to eq Date.current - 10
    end

    it "購入 (入庫) は消費量に入らない" do
      record_usage(item, days_ago: 10, quantity: 3)
      stock_up(item, 60, days_ago: 5)

      expect(snapshot.consumed).to eq 3
    end

    it "棚卸のプラス差分 (正の調整) は消費量に入らない" do
      record_usage(item, days_ago: 10, quantity: 3)
      count_stock(item, 600, days_ago: 5)

      expect(snapshot.consumed).to eq 3
    end

    it "消費が 1 件も無ければ 0" do
      expect(snapshot.consumed).to eq 0
      expect(snapshot.event_count).to eq 0
    end
  end

  describe "在庫不足の補填" do
    # 補填の入庫は正の adjustment なので分子に入らない
    # (docs/spec/01-domain-model.md 5 節の Phase 8 からの申し送り)
    it "在庫不足を補填した使用も消費に数える" do
      record_usages(item, interval: 20, times: 3)

      # 窓は 3 件目 (= 最古) の消費イベント日 today - 40 から。開始日当日は数えない
      expect(snapshot.consumed).to eq 2
      expect(snapshot.event_count).to eq 3
    end
  end

  describe "消費イベント (同じ日は 1 件)" do
    before { stock_up(item, 500, days_ago: 200) }

    it "同じ日に 2 回記録しても消費イベントは 1 件" do
      record_usage(item, days_ago: 20)
      record_usage(item, days_ago: 0)
      record_usage(item, days_ago: 0)

      expect(snapshot.event_count).to eq 2
      expect(snapshot.consumed).to eq 3
    end

    it "FEFO で 2 行に分かれた使用も消費イベントは 1 件" do
      tracked = create(:item, unit: "個", tracks_expiry: true)
      create(:lot, item: tracked, initial_quantity: 2, expires_on: Date.current + 10,
        acquired_on: Date.current - 200)
      create(:lot, item: tracked, initial_quantity: 5, expires_on: Date.current + 40,
        acquired_on: Date.current - 200)
      record_usage(tracked, days_ago: 0, quantity: 3)

      expect(tracked.stock_movements.kind_usage.count).to eq 2
      expect(snapshot(tracked).event_count).to eq 1
      expect(snapshot(tracked).consumed).to eq 3
    end

    # 「直近 5 件目のイベント日」を数えるときも同じ日は 1 件。行に順位を付ける SQL が
    # ROW_NUMBER / RANK だと今日の 3 行で枠を使い切り、窓が today - 90 日に縮んでしまう
    it "同じ日の複数記録は 5 件目を数えるときも 1 件 (DENSE_RANK)" do
      record_usages(item, interval: 30, times: 6)
      2.times { record_usage(item, days_ago: 0) }

      # 消費イベント日は today / 30 / 60 / 90 / 120 / 150 日前。5 件目は today - 120
      expect(snapshot.observed_days).to eq 120
      expect(snapshot.event_count).to eq 5
      expect(snapshot.consumed).to eq 6
    end

    it "1 回の棚卸で movement が複数行に分かれても消費イベントは棚卸日の 1 件" do
      tracked = create(:item, unit: "個", tracks_expiry: true)
      create(:lot, item: tracked, initial_quantity: 5, expires_on: Date.current + 10,
        acquired_on: Date.current - 200)
      create(:lot, item: tracked, initial_quantity: 5, expires_on: Date.current + 40,
        acquired_on: Date.current - 200)
      count_stock(tracked, 3, days_ago: 10)

      expect(tracked.stock_movements.kind_adjustment.where(quantity: ...0).count).to eq 2
      expect(snapshot(tracked).event_count).to eq 1
      expect(snapshot(tracked).consumed).to eq 7
    end
  end

  describe "集計窓 (仕様 3 節)" do
    it "直近 5 件目の消費イベント日まで伸びる (6 件目は窓の外)" do
      record_usages(item, interval: 30, times: 6)

      # 5 件目は today - 120。そこが窓の開始で、終わりは anchor (today)
      expect(snapshot.observed_days).to eq 120
    end

    it "窓の開始日当日の消費は consumed に含まれないが、event_count には含まれる" do
      record_usages(item, interval: 30, times: 6)

      # (today - 120, today] の 4 件ぶんが consumed、[today - 120, today] の 5 件が event_count
      expect(snapshot.consumed).to eq 4
      expect(snapshot.event_count).to eq 5
    end

    it "窓の開始日より古い使用記録は consumed にも event_count にも入らない" do
      record_usages(item, interval: 30, times: 6)

      # 6 件目 (today - 150) は窓の外。入れると consumed 5 / event_count 6 になる
      expect(snapshot.consumed).to eq 4
      expect(snapshot.event_count).to eq 5
    end

    it "消費イベントが少なければ窓は today - 90 日で止まる" do
      stock_up(item, 500, days_ago: 200)
      record_usage(item, days_ago: 10)
      record_usage(item, days_ago: 0)

      expect(snapshot.observed_days).to eq 90
    end

    it "tracking_started_on より前には遡らない" do
      stock_up(item, 50, days_ago: 30)
      record_usage(item, days_ago: 20)
      record_usage(item, days_ago: 10)

      # 90 日窓のままだとペースが 1/3 に過小評価される
      expect(item.reload.tracking_started_on).to eq Date.current - 30
      expect(snapshot.observed_days).to eq 30
      expect(snapshot.consumed).to eq 2
    end

    it "today - 730 日より前には遡らない" do
      record_usages(item, interval: 200, times: 5)

      # 5 件目は today - 800。下限の today - 730 で打ち切られ、終わりは today のまま
      expect(snapshot.observed_days).to eq 730
      expect(snapshot.consumed).to eq 4
      expect(snapshot.event_count).to eq 4
    end

    it "窓の開始が消費イベント日なら、窓の終わりは anchor にそろう" do
      record_usages(item, interval: 30, times: 5, last_used_days_ago: 10)

      # 開始 (today - 130) も終わり (today - 10) も消費イベント日。today までは伸ばさない
      expect(snapshot.observed_days).to eq 120
      expect(snapshot.anchor_on).to eq Date.current - 10
    end

    it "窓の開始が today - 90 日なら、窓の終わりは today のまま" do
      stock_up(item, 500, days_ago: 200)
      record_usage(item, days_ago: 40)
      record_usage(item, days_ago: 20)

      expect(snapshot.observed_days).to eq 90
    end

    # Phase 9 からの申し送り: 過去日の棚卸を確定すると最初の在庫イベント日が前に動く
    it "過去日の棚卸を確定すると tracking_started_on が前に動き、窓の下限も伸びる" do
      stock_up(item, 50, days_ago: 20)
      record_usage(item, days_ago: 10)
      record_usage(item, days_ago: 5)

      expect(snapshot.observed_days).to eq 20

      count_stock(item, 40, days_ago: 100)

      expect(item.reload.tracking_started_on).to eq Date.current - 100
      expect(snapshot.observed_days).to eq 95
    end
  end

  describe "在庫 q (期限切れロットを除く)" do
    let(:item) { create(:item, unit: "個", tracks_expiry: true) }

    it "期限切れロットの残数は除く" do
      create(:lot, item: item, initial_quantity: 3, expires_on: Date.current + 10)
      create(:lot, item: item, initial_quantity: 2, expires_on: Date.current - 1)

      expect(item.reload.current_quantity).to eq 5
      expect(snapshot.quantity).to eq 3
    end

    it "全ロットが期限切れなら 0 になる" do
      create(:lot, item: item, initial_quantity: 4, expires_on: Date.current - 1)

      expect(snapshot.quantity).to eq 0
    end

    # 「今日が期限」はまだ期限切れではない (Lot#expired? / Stock::Allocator と同じ基準)
    it "今日が期限のロットは在庫に数える" do
      create(:lot, item: item, initial_quantity: 4, expires_on: Date.current)

      expect(snapshot.quantity).to eq 4
    end

    it "期限の無いロット (棚卸のプラス差分など) は在庫に数える" do
      create(:lot, :adjustment, item: item, initial_quantity: 6, expires_on: nil)

      expect(snapshot.quantity).to eq 6
    end

    it "使い切ったロットは在庫に数えない" do
      create(:lot, item: item, initial_quantity: 2, expires_on: Date.current + 10)
      record_usage(item, days_ago: 0, quantity: 2)

      expect(snapshot.quantity).to eq 0
    end
  end

  describe "u (1 回あたりの使用数)" do
    before { stock_up(item, 500, days_ago: 200) }

    it "使用記録が無ければ 1" do
      expect(snapshot.unit_usage).to eq 1
    end

    it "窓内の使用記録の数量の中央値 (平均ではない)" do
      record_usage(item, days_ago: 30, quantity: 1)
      record_usage(item, days_ago: 20, quantity: 2)
      record_usage(item, days_ago: 10, quantity: 9)

      # 平均なら 4
      expect(snapshot.unit_usage).to eq 2
    end

    it "中央値が小数なら四捨五入する" do
      record_usage(item, days_ago: 30, quantity: 1)
      record_usage(item, days_ago: 20, quantity: 2)

      expect(snapshot.unit_usage).to eq 2
    end

    # 銀行丸め (round(half: :even)) だと 2 になってしまう
    it "中央値 2.5 は 3 に丸める (偶数丸めにしない)" do
      record_usage(item, days_ago: 20, quantity: 2)
      record_usage(item, days_ago: 10, quantity: 3)

      expect(snapshot.unit_usage).to eq 3
    end

    it "件数が奇数なら中央の値をそのまま使う (切り上げない)" do
      record_usage(item, days_ago: 30, quantity: 1)
      record_usage(item, days_ago: 20, quantity: 1)
      record_usage(item, days_ago: 10, quantity: 2)

      expect(snapshot.unit_usage).to eq 1
    end

    it "棚卸のマイナス差分は u に入らない (消費量には入る)" do
      count_stock(item, 400, days_ago: 10)

      expect(snapshot.consumed).to eq 100
      expect(snapshot.unit_usage).to eq 1
    end

    # 窓の開始日 (today - 200) 当日の記録は半開区間の外。入れると中央値が 3 になる
    it "窓の開始日当日の使用記録は u に入らない" do
      record_usage(item, days_ago: 200, quantity: 20)
      record_usage(item, days_ago: 10, quantity: 1)
      record_usage(item, days_ago: 5, quantity: 3)

      expect(snapshot.observed_days).to eq 195
      expect(snapshot.unit_usage).to eq 2
    end
  end

  describe "アンカー" do
    it "消費イベントがあれば最後の消費イベント日" do
      stock_up(item, 500, days_ago: 200)
      record_usage(item, days_ago: 7)

      expect(snapshot.anchor_on).to eq Date.current - 7
    end

    it "消費イベントが無ければ tracking_started_on (最初の在庫イベント日)" do
      stock_up(item, 5, days_ago: 40)

      expect(snapshot.anchor_on).to eq Date.current - 40
    end

    it "在庫イベントが 1 件も無ければ nil" do
      expect(snapshot.anchor_on).to be_nil
    end

    # anchor が無いのに窓だけ伸ばすと窓の終わりが nil になる (仕様 4 節の防御)
    it "アンカーが無くても例外にならず observed_days が出る" do
      expect(snapshot.observed_days).to eq 90
    end

    # 台帳には消費があるのにキャッシュ列だけ欠けた状態。窓を消費イベント日まで伸ばすと
    # 窓の終わり (anchor) が nil になり、nil - Date で一覧もダッシュボードも 500 になる
    it "キャッシュ列だけ欠けていても (台帳に消費あり) 例外にならず unknown になる" do
      record_usages(item, interval: 30, times: 5)
      item.update_columns(last_consumed_on: nil, tracking_started_on: nil)

      expect(snapshot.anchor_on).to be_nil
      expect(snapshot.observed_days).to eq 90
      expect(Forecast::ItemForecaster.call(item.reload).pace).not_to be_known
    end

    it "last_consumed_on だけ欠けていても例外にならず unknown になる" do
      record_usages(item, interval: 30, times: 5)
      item.update_columns(last_consumed_on: nil)

      # anchor は tracking_started_on (= 5 件目の消費イベント日) に落ちるので観測は 0 日
      expect(snapshot.anchor_on).to eq Date.current - 120
      expect(snapshot.observed_days).to eq 0
      expect(Forecast::ItemForecaster.call(item.reload).pace).not_to be_known
    end
  end

  describe "品目の設定" do
    it "estimation_mode は Symbol で渡す (Forecast::Pace は文字列を受け付けない)" do
      item.update!(estimation_mode: :none)

      expect(snapshot.mode).to eq :none
    end

    it "manual_interval_days をそのまま渡す" do
      item.update!(estimation_mode: :manual, manual_interval_days: 45)

      expect(snapshot.mode).to eq :manual
      expect(snapshot.manual_interval_days).to eq 45
    end

    it "minimum_quantity をそのまま渡す" do
      item.update!(minimum_quantity: 4)

      expect(snapshot.minimum_quantity).to eq 4
    end

    it "品目ごとの閾値が既定値を上書きする" do
      item.update!(soon_threshold_days: 30, urgent_threshold_days: 10)

      expect(snapshot.thresholds.soon_days).to eq 30
      expect(snapshot.thresholds.urgent_days).to eq 10
    end

    it "未設定の閾値は既定値のまま (nil で上書きしない)" do
      item.update!(soon_threshold_days: 30)

      expect(snapshot.thresholds.soon_days).to eq 30
      expect(snapshot.thresholds.urgent_days).to eq Forecast::Thresholds.default.urgent_days
    end

    it "today は引数で差し替えられる (spec で固定するため)" do
      other = Date.current - 3

      expect(described_class.call(item, today: other).today).to eq other
    end
  end
end
