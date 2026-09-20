require "rails_helper"

RSpec.describe Forecast::BatchForecaster do
  before { freeze_time }

  # 性質の違う品目をひととおり作る。一括集計 (SQL) と 1 件ずつの判定が食い違いやすいのは
  # 「窓が品目ごとに違う」ところなので、窓の決まり方が違う品目を必ず混ぜる
  def mixed_items # rubocop:disable Metrics/AbcSize
    no_history = create(:item, name: "りれきなし")

    once = create(:item, name: "いちどだけ")
    stock_up(once, 5, days_ago: 60)
    record_usage(once, days_ago: 10)

    frequent = create(:item, name: "ひんぱん")
    stock_up(frequent, 100, days_ago: 200)
    record_usages(frequent, interval: 5, times: 10, last_used_days_ago: 1)

    seasonal = create(:item, name: "きせつひん")
    record_usages(seasonal, interval: 182, times: 5)

    with_purposes = create(:item, name: "ようとつき", tracks_purposes: true)
    purpose = create(:item_purpose, item: with_purposes, name: "リモコン", default_quantity: 2)
    stock_up(with_purposes, 20, days_ago: 100)
    3.times { |n| record_usage(with_purposes, days_ago: 30 * n, quantity: 2, item_purpose: purpose) }

    counted = create(:item, name: "たなおろしのマイナス")
    stock_up(counted, 30, days_ago: 100)
    count_stock(counted, 20, days_ago: 20)

    compensated = create(:item, name: "ほてんあり")
    record_usages(compensated, interval: 15, times: 4)

    disposed = create(:item, name: "はいきあり", tracks_expiry: true)
    create(:lot, item: disposed, initial_quantity: 10,
      acquired_on: Date.current - 60, expires_on: Date.current + 40)
    record_usage(disposed, days_ago: 30, quantity: 2)
    dispose(disposed, 4, days_ago: 3, reason: :damaged)

    expired = create(:item, name: "きげんぎれのざいこ", tracks_expiry: true)
    create(:lot, item: expired, initial_quantity: 6,
      acquired_on: Date.current - 40, expires_on: Date.current - 1)

    manual = create(:item, :manual_estimation, name: "しゅどう")
    stock_up(manual, 2, days_ago: 10)

    none = create(:item, name: "よそくしない", estimation_mode: :none)

    minimum = create(:item, name: "さいていざいこあり", minimum_quantity: 5)
    stock_up(minimum, 3, days_ago: 30)

    thresholds = create(:item, name: "しきいちうわがき",
      soon_threshold_days: 60, urgent_threshold_days: 40)
    stock_up(thresholds, 10, days_ago: 200)
    record_usages(thresholds, interval: 10, times: 6)

    [ no_history, once, frequent, seasonal, with_purposes, counted, compensated,
      disposed, expired, manual, none, minimum, thresholds ].each(&:reload)
  end

  # ここが Phase 10 の肝。一括集計の SQL を書き換えたらまずここが落ちる
  it "結果は各品目を ItemForecaster で個別に判定した結果と一致する" do
    items = mixed_items
    expected = items.to_h { |item| [ item.id, Forecast::ItemForecaster.call(item) ] }

    expect(described_class.call(items)).to eq expected
  end

  it "判定が unknown だけに寄っていない (spec が空回りしていない)" do
    statuses = described_class.call(mixed_items).values.map(&:status)

    expect(statuses.uniq).to include(:urgent, :soon, :ok, :unknown)
  end

  it "Item の Relation をそのまま渡せる" do
    mixed_items

    expect(described_class.call(Item.active.ordered).keys).to match_array Item.active.ids
  end

  # 予測しない (docs/spec/02-forecast.md 9 節: 一覧・ダッシュボード・買い物リストから除外)
  it "アーカイブ済みの品目は結果に入らない" do
    active = create(:item, name: "つかってる")
    archived = create(:item, :archived, name: "むかしの洗剤")
    stock_up(active, 1)
    stock_up(archived, 1)

    results = described_class.call(Item.all)

    expect(results.keys).to eq [ active.id ]
  end

  it "品目が 1 件も無ければ空のハッシュを返す (クエリも出さない)" do
    items = Item.all.to_a
    results = nil

    expect(count_queries { results = described_class.call(items) }).to eq 0
    expect(results).to eq({})
  end

  describe "クエリ数" do
    # N 品目に対してクエリは定数回 (1 件だと同じ SQL がクエリキャッシュに当たるので 2 件から)
    it "品目が増えてもクエリ数は増えない" do
      2.times { |n| stock_up(create(:item), 3, days_ago: n + 1) }
      few = Item.all.to_a
      described_class.call(few) # ウォームアップ

      baseline = count_queries { described_class.call(few) }
      3.times { |n| stock_up(create(:item), 3, days_ago: n + 1) }
      many = Item.all.to_a

      expect(many.size).to eq 5
      expect(count_queries { described_class.call(many) }).to eq baseline
    end

    # 窓を決めるのに 1 往復するので 2 段階 (イベント日と在庫 → 窓 → 窓の中の集計)
    it "発行するクエリは 4 本" do
      2.times { stock_up(create(:item), 3) }
      items = Item.all.to_a
      described_class.call(items) # ウォームアップ

      expect(count_queries { described_class.call(items) }).to eq 4
    end
  end

  describe "判定の中身" do
    it "最低在庫を下回る品目は urgent になる" do
      item = create(:item, minimum_quantity: 5)
      stock_up(item, 3, days_ago: 30)

      result = described_class.call([ item.reload ]).fetch(item.id)

      expect(result.status).to eq :urgent
      expect(result.reason).to eq :minimum
    end

    it "全ロットが期限切れの品目は在庫 0 として urgent になる" do
      item = create(:item, tracks_expiry: true)
      create(:lot, item: item, initial_quantity: 4,
        acquired_on: Date.current - 40, expires_on: Date.current - 1)

      result = described_class.call([ item.reload ]).fetch(item.id)

      expect(result.status).to eq :urgent
      expect(result.reason).to eq :out_of_stock
    end

    it "予測しない設定 (none) の品目は在庫 0 でも unknown のまま" do
      item = create(:item, estimation_mode: :none)

      expect(described_class.call([ item ]).fetch(item.id).status).to eq :unknown
    end

    it "品目ごとの閾値の上書きが効く (残り 30 日は既定なら ok、soon 60 日なら soon)" do
      # urgent は残り 30 日より小さくしておく (30 日以上にすると soon ではなく urgent になる)
      item = create(:item, soon_threshold_days: 60, urgent_threshold_days: 10)
      record_usages(item, interval: 5, times: 19)
      stock_up(item, 5)
      snapshot = Forecast::SnapshotBuilder.call(item.reload)
      result = described_class.call([ item ]).fetch(item.id)

      expect(snapshot.thresholds.soon_days).to eq 60
      expect(result.days_left).to eq 30
      expect(result.status).to eq :soon
      # 上書きを無視して既定の 21 日で判定すると ok になってしまう
      expect(Forecast::Calculator.call(snapshot.with(thresholds: Forecast::Thresholds.default)).status)
        .to eq :ok
    end
  end
end
