require "rails_helper"

RSpec.describe Expiry::Evaluator do
  before { freeze_time }

  let(:item) { create(:item, name: "レトルトカレー", unit: "箱", tracks_expiry: true) }

  def result(target = item)
    described_class.for(target)
  end

  def lot(expires_on:, quantity: 1)
    create(:lot, item: item, initial_quantity: quantity, expires_on: expires_on,
      acquired_on: Date.current - 10)
  end

  describe "品目のステータス (保有ロットの最悪値)" do
    it "ロットが無ければ fresh" do
      expect(result.status).to eq :fresh
    end

    it "期限切れのロットがあれば expired" do
      lot(expires_on: Date.current + 100)
      lot(expires_on: Date.current - 1)

      expect(result.status).to eq :expired
      expect(result.expired_count).to eq 1
    end

    it "期限間近のロットだけなら expiring_soon" do
      lot(expires_on: Date.current + 10)
      lot(expires_on: Date.current + 100)

      expect(result.status).to eq :expiring_soon
      expect(result.expiring_soon_count).to eq 1
    end

    it "期限に余裕があれば fresh" do
      lot(expires_on: Date.current + 100)

      expect(result.status).to eq :fresh
    end

    it "期限を入れていないロットは fresh のまま (棚卸のプラス差分の調整ロットなど)" do
      create(:lot, :adjustment, item: item, initial_quantity: 3, expires_on: nil)

      expect(result.status).to eq :fresh
      expect(result.nearest_expires_on).to be_nil
    end
  end

  describe "残数の扱い" do
    # 残数 1 以上のロットだけを見る (仕様 12 節)
    it "使い切ったロットは期限切れでも数えない" do
      expired = lot(expires_on: Date.current - 1, quantity: 2)
      lot(expires_on: Date.current + 100, quantity: 5)
      create(:stock_movement, lot: expired, kind: :usage, quantity: -2)
      Stock::Recalculator.call(item)

      expect(result.status).to eq :fresh
      expect(result.expired_count).to eq 0
    end
  end

  describe "境界" do
    # Lot#expired? / Stock::Allocator と一致させる
    it "今日が期限のロットはまだ期限切れではない" do
      lot(expires_on: Date.current)

      expect(result.status).to eq :expiring_soon
      expect(result.expired_count).to eq 0
    end

    it "警告日数ちょうど (既定 30 日) は expiring_soon" do
      lot(expires_on: Date.current + 30)

      expect(result.status).to eq :expiring_soon
    end

    it "警告日数の 1 日先は fresh" do
      lot(expires_on: Date.current + 31)

      expect(result.status).to eq :fresh
    end

    it "品目ごとの期限警告日数が効く" do
      item.update!(expiry_warning_days: 7)
      lot(expires_on: Date.current + 10)

      expect(result.status).to eq :fresh
    end
  end

  describe "最も近い期限" do
    it "在庫のあるロットの中でいちばん早い期限を返す" do
      lot(expires_on: Date.current + 100)
      lot(expires_on: Date.current + 20)

      expect(result.nearest_expires_on).to eq Date.current + 20
    end

    it "期限切れのロットがあればその日付を返す (過去でも隠さない)" do
      lot(expires_on: Date.current - 5)
      lot(expires_on: Date.current + 20)

      expect(result.nearest_expires_on).to eq Date.current - 5
    end
  end

  describe "一括判定" do
    it "品目ごとの結果をハッシュで返す" do
      other = create(:item, name: "かんづめ", tracks_expiry: true)
      lot(expires_on: Date.current - 1)
      create(:lot, item: other, initial_quantity: 2, expires_on: Date.current + 100)

      results = described_class.call([ item, other ])

      expect(results.fetch(item.id).status).to eq :expired
      expect(results.fetch(other.id).status).to eq :fresh
    end

    # 一覧・ダッシュボードから引くので N+1 にしない
    it "品目が増えてもクエリは 1 本のまま" do
      2.times { create(:lot, item: create(:item), initial_quantity: 1, expires_on: Date.current + 3) }
      few = Item.all.to_a
      described_class.call(few) # ウォームアップ

      baseline = count_queries { described_class.call(few) }
      3.times { create(:lot, item: create(:item), initial_quantity: 1, expires_on: Date.current + 3) }
      many = Item.all.to_a

      expect(baseline).to eq 1
      expect(count_queries { described_class.call(many) }).to eq baseline
    end

    # 予測 (Forecast::BatchForecaster) と対称にする。落とさないと
    # 「一覧の期限切れバッジにはアーカイブ済みが出るのに、要購入には出ない」という
    # ねじれが起き、日次ダイジェスト (Phase 12) もアーカイブ済みを通知してしまう
    it "アーカイブ済みの品目は結果に入らない" do
      archived = create(:item, :archived, name: "むかしのレトルト", tracks_expiry: true)
      create(:lot, item: archived, initial_quantity: 2, expires_on: Date.current - 1)
      lot(expires_on: Date.current - 1)

      results = described_class.call([ item, archived ])

      expect(results.keys).to eq [ item.id ]
    end

    # 品目詳細はアーカイブ済みでも開けるので、1 品目版は判定する
    it "1 品目版はアーカイブ済みでも判定する (品目詳細用)" do
      archived = create(:item, :archived, name: "むかしのレトルト", tracks_expiry: true)
      create(:lot, item: archived, initial_quantity: 2, expires_on: Date.current - 1)

      expect(described_class.for(archived).status).to eq :expired
    end

    it "品目が 1 件も無ければクエリを出さない" do
      items = []
      results = nil

      expect(count_queries { results = described_class.call(items) }).to eq 0
      expect(results).to eq({})
    end
  end
end
