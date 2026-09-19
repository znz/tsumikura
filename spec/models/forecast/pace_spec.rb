require_relative "forecast_helper"

RSpec.describe Forecast::Pace do
  include ForecastSpecHelper

  describe ".for (auto モード)" do
    it "消費イベントが 1 件しかなければ間隔を 1 つも測れないので unknown になる" do
      pace = described_class.for(snapshot(event_count: 1, observed_days: 90, consumed: 3))

      expect(pace).not_to be_known
      expect(pace.per_day).to be_nil
      expect(pace.source).to eq :unknown
    end

    it "検算例 1: 観測 90 日・消費 18 個なら per_day は Rational(1, 5) になる" do
      pace = described_class.for(snapshot(event_count: 18, observed_days: 90, consumed: 18, anchor_on: today))

      expect(pace).to be_known
      expect(pace.per_day).to eq Rational(1, 5)
      expect(pace.source).to eq :auto
      expect(pace.event_count).to eq 18
      expect(pace.observed_days).to eq 90
    end

    it "消費イベントが 0 件なら unknown になる (ペース 0 とは扱わない)" do
      pace = described_class.for(snapshot(event_count: 0, observed_days: 90, consumed: 0))

      expect(pace).not_to be_known
    end

    it "消費イベント 2 件でも観測 13 日なら観測が浅すぎるので unknown になる" do
      pace = described_class.for(snapshot(event_count: 2, observed_days: 13, consumed: 1))

      expect(pace).not_to be_known
    end

    it "消費イベント 2 件・観測 14 日ならペースが出る (全 2 件で古い方が窓の開始のケース)" do
      pace = described_class.for(snapshot(event_count: 2, observed_days: 14, consumed: 1, anchor_on: today))

      expect(pace).to be_known
      expect(pace.per_day).to eq Rational(1, 14)
    end

    it "min_samples は Snapshot の閾値を見る (3 に上げると消費イベント 2 件では unknown)" do
      thresholds = Forecast::Thresholds.default.with(min_samples: 3)
      pace = described_class.for(snapshot(event_count: 2, observed_days: 90, consumed: 2, thresholds: thresholds))

      expect(pace).not_to be_known
    end

    it "min_observed_days は Snapshot の閾値を見る (30 に上げると観測 20 日では unknown)" do
      thresholds = Forecast::Thresholds.default.with(min_observed_days: 30)
      pace = described_class.for(snapshot(event_count: 2, observed_days: 20, consumed: 2, thresholds: thresholds))

      expect(pace).not_to be_known
    end

    it "検算例 2: 観測 728 日・消費 4 個なら per_day は Rational(1, 182) になる" do
      pace = described_class.for(snapshot(event_count: 5, observed_days: 728, consumed: 4, anchor_on: today))

      expect(pace.per_day).to eq Rational(1, 182)
    end
  end

  describe ".for (manual モード)" do
    def manual_snapshot(**overrides)
      snapshot(mode: :manual, manual_interval_days: 5, anchor_on: today - 1, **overrides)
    end

    it "manual_interval_days が 5 なら per_day は Rational(1, 5) になる" do
      pace = described_class.for(manual_snapshot)

      expect(pace).to be_known
      expect(pace.per_day).to eq Rational(1, 5)
      expect(pace.source).to eq :manual
    end

    it "消費イベント 0 件・観測 0 日でも既知になる (窓の条件を適用しない)" do
      pace = described_class.for(manual_snapshot(event_count: 0, observed_days: 0))

      expect(pace).to be_known
      expect(pace.per_day).to eq Rational(1, 5)
    end

    it "manual_interval_days が未設定なら unknown になる" do
      pace = described_class.for(manual_snapshot(manual_interval_days: nil))

      expect(pace).not_to be_known
    end

    it "anchor_on が nil なら unknown になる (起点が無いと予測日を出せない)" do
      pace = described_class.for(manual_snapshot(anchor_on: nil))

      expect(pace).not_to be_known
    end
  end

  describe ".for (auto モードで起点が無い場合)" do
    it "anchor_on が nil なら unknown になる" do
      # anchor はキャッシュ列・event_count は集計なので、ずれると起点だけ欠けることがある。
      # 例外にせず「確信が持てないときは黙る」(設計原則 4)
      pace = described_class.for(snapshot(event_count: 18, observed_days: 90, consumed: 18, anchor_on: nil))

      expect(pace).not_to be_known
    end
  end

  describe ".for (未知のモード)" do
    it "Symbol 以外の値 (AR の enum 文字列など) を渡したら ArgumentError にする" do
      expect { described_class.for(snapshot(mode: "none")) }.to raise_error(ArgumentError, /none/)
    end

    it "mode が nil なら ArgumentError にする" do
      expect { described_class.for(snapshot(mode: nil)) }.to raise_error(ArgumentError)
    end
  end

  describe ".for (none モード)" do
    it "実績が十分あっても常に unknown になる" do
      pace = described_class.for(snapshot(mode: :none, event_count: 18, observed_days: 90, consumed: 18))

      expect(pace).not_to be_known
      expect(pace.source).to eq :unknown
    end
  end
end
