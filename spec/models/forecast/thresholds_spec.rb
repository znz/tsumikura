require_relative "forecast_helper"

RSpec.describe Forecast::Thresholds do
  describe ".default" do
    it "config/tsumikura.yml の既定値を返す" do
      thresholds = described_class.default

      expect(thresholds.soon_days).to eq 21
      expect(thresholds.urgent_days).to eq 7
      expect(thresholds.window_min_days).to eq 90
      expect(thresholds.window_events).to eq 5
      expect(thresholds.window_max_days).to eq 730
      expect(thresholds.min_samples).to eq 2
      expect(thresholds.min_observed_days).to eq 14
    end
  end

  describe "#with" do
    it "品目固有の閾値が既定値を上書きし、他の値は既定のまま残る" do
      thresholds = described_class.default.with(soon_days: 30, urgent_days: 10)

      expect(thresholds.soon_days).to eq 30
      expect(thresholds.urgent_days).to eq 10
      expect(thresholds.window_min_days).to eq 90
      expect(thresholds.min_observed_days).to eq 14
    end

    it "上書きしても既定値のオブジェクトは変わらない" do
      described_class.default.with(soon_days: 30)

      expect(described_class.default.soon_days).to eq 21
    end
  end

  describe "設定値の検証" do
    it "min_samples が 2 未満なら ArgumentError にする (1 件では間隔を測れない)" do
      expect { described_class.default.with(min_samples: 1) }.to raise_error(ArgumentError, /min_samples/)
    end

    it "min_observed_days が 1 未満なら ArgumentError にする (ゼロ除算の予防)" do
      expect { described_class.default.with(min_observed_days: 0) }.to raise_error(ArgumentError, /min_observed_days/)
    end
  end
end
