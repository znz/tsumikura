require "spec_helper"

# 期限判定は予測と同じく DB にも Rails にも依存させない (docs/spec/02-forecast.md 12 節)。
# Rails のオートロードが効かないので対象ファイルを直接読む
require_relative "../../../app/models/expiry/status"

RSpec.describe Expiry::Status do
  # 2026/9/20 を「今日」とする
  let(:today) { Date.new(2026, 9, 20) }

  def status_for(expires_on, warning_days: 30)
    described_class.for(expires_on: expires_on, today: today, warning_days: warning_days)
  end

  describe ".for" do
    it "期限が今日より前なら expired" do
      expect(status_for(today - 1)).to eq :expired
    end

    # Lot#expired? / Stock::Allocator と同じ基準にする (「今日が期限」はまだ使える)
    it "期限が今日なら expired ではない" do
      expect(status_for(today)).to eq :expiring_soon
    end

    it "期限が警告日数ちょうどなら expiring_soon" do
      expect(status_for(today + 30)).to eq :expiring_soon
    end

    it "期限が警告日数の 1 日先なら fresh" do
      expect(status_for(today + 31)).to eq :fresh
    end

    it "期限が無ければ fresh (棚卸のプラス差分で作る調整ロットなど)" do
      expect(status_for(nil)).to eq :fresh
    end

    it "品目ごとの警告日数を使う (7 日なら 10 日後は fresh)" do
      expect(status_for(today + 10, warning_days: 7)).to eq :fresh
      expect(status_for(today + 7, warning_days: 7)).to eq :expiring_soon
    end

    it "警告日数 0 でも「今日が期限」は expiring_soon (期限切れにはしない)" do
      expect(status_for(today, warning_days: 0)).to eq :expiring_soon
    end
  end

  describe ".worst" do
    it "ロットが 1 件も無ければ fresh" do
      expect(described_class.worst([])).to eq :fresh
    end

    it "期限切れが 1 件でもあれば expired" do
      expect(described_class.worst([ :fresh, :expiring_soon, :expired ])).to eq :expired
    end

    it "期限間近が混ざれば expiring_soon" do
      expect(described_class.worst([ :fresh, :expiring_soon ])).to eq :expiring_soon
    end

    it "すべて fresh なら fresh" do
      expect(described_class.worst([ :fresh, :fresh ])).to eq :fresh
    end
  end
end
