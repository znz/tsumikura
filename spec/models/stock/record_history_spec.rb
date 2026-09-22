require "rails_helper"

# 品目詳細の「最近の記録」(10 件) と全履歴 (docs/spec/03-screens.md 画面 3b) が
# 同じ並び・同じ除外条件を使うための集約。
RSpec.describe Stock::RecordHistory, type: :model do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:item) { create(:item, name: "たまご", unit: "個") }

  it "使用・購入・廃棄・棚卸の調整を新しい順に混ぜる" do
    stock_up(item, 12, days_ago: 4)
    count_stock(item, 10, days_ago: 3)
    dispose(item, 1, days_ago: 2)
    usage = record_usage(item, quantity: 2, days_ago: 1)

    records = described_class.call(item)

    expect(records.first).to eq usage
    expect(records.map(&:class)).to eq [ UsageRecord, StockMovement, StockMovement, Lot ]
    expect(records.map(&:recorded_on))
      .to eq [ Date.current - 1, Date.current - 2, Date.current - 3, Date.current - 4 ]
  end

  it "limit を渡さなければ全件返す" do
    record_usages(item, interval: 1, times: 12)

    expect(described_class.call(item).size).to eq 12
  end

  it "limit を渡すと新しい順にその件数だけ返す" do
    records = record_usages(item, interval: 1, times: 12)

    expect(described_class.call(item, limit: 10)).to eq records.take(10)
  end

  # 在庫不足の補填で作られた調整ロットと movement はユーザーの操作ではない
  # (補填したことはトーストで伝えている)
  it "補填の調整は出さない" do
    usage = record_usage(item, quantity: 2)

    expect(described_class.call(item)).to eq [ usage ]
  end

  it "他の品目の記録は混ざらない" do
    record_usage(create(:item), quantity: 1)
    usage = record_usage(item, quantity: 1)

    expect(described_class.call(item)).to eq [ usage ]
  end

  # 行ごとに用途・店舗・棚卸を出すので、includes しないと記録の数だけクエリが増える。
  # 品目詳細は 10 件 + 1 件を引くので、limit が増えてもクエリが増えないことも合わせて見る
  it "記録が増えてもクエリ数は増えない (用途と店舗を includes)" do
    tracked = create(:item, name: "単 3 電池", unit: "本", tracks_purposes: true)
    purpose = create(:item_purpose, item: tracked, name: "リモコン")
    # 店舗が 1 件だとクエリキャッシュに当たって基準が 1 本少なくなるので、毎回別の店舗にする
    add_records = lambda do
      stock_up(tracked, 5, store: create(:store))
      record_usage(tracked, quantity: 1, item_purpose: purpose)
      dispose(tracked, 1)
    end

    2.times { add_records.call }
    described_class.call(tracked, limit: 11) # ウォームアップ

    baseline = count_queries { described_class.call(tracked, limit: 11) }
    3.times { add_records.call }

    expect(count_queries { described_class.call(tracked, limit: 11) }).to eq baseline
  end
end
