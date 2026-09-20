require "rails_helper"

# 仕様 10 節の検算例を、**台帳のデータから**通しで再現する。
# Phase 3 は PORO (Snapshot を手で組む) だけで検証したので、ここでは
# 「記録を作れば同じ数値が出る」ことを確かめる (SnapshotBuilder -> Calculator)。
RSpec.describe Forecast::ItemForecaster do
  before { freeze_time }

  describe "検算例 1: トイレットペーパー (5 日に 1 ロール・最後は 2 日前・在庫 3)" do
    let(:item) { create(:item, name: "トイレットペーパー", unit: "ロール") }

    before do
      # 2, 7, ..., 92 日前。92 日前のイベントは窓 (today - 90) の外に落ちる
      record_usages(item, interval: 5, times: 19, last_used_days_ago: 2)
      stock_up(item, 3)
    end

    it "consumed 18 / observed 90 / event_count 18 になる" do
      snapshot = Forecast::SnapshotBuilder.call(item.reload)

      expect(snapshot.consumed).to eq 18
      expect(snapshot.observed_days).to eq 90
      expect(snapshot.event_count).to eq 18
      expect(snapshot.unit_usage).to eq 1
      expect(snapshot.quantity).to eq 3
      expect(snapshot.anchor_on).to eq Date.current - 2
    end

    it "ペースは 1/5・在庫切れ予測日は today + 18 で soon" do
      result = described_class.call(item.reload)

      expect(result.pace.per_day).to eq Rational(1, 5)
      expect(result.need_by_on).to eq Date.current + 18
      expect(result.days_left).to eq 18
      expect(result.status).to eq :soon
      expect(result.reason).to eq :pace
    end
  end

  describe "検算例 2: くん煙剤 (182 日おきに 5 回・最後は今日・在庫 0)" do
    let(:item) { create(:item, name: "くん煙剤", unit: "個") }

    before { record_usages(item, interval: 182, times: 5) }

    it "consumed 4 / event_count 5 / observed 728 になる" do
      snapshot = Forecast::SnapshotBuilder.call(item.reload)

      expect(snapshot.consumed).to eq 4
      expect(snapshot.event_count).to eq 5
      expect(snapshot.observed_days).to eq 728
      expect(snapshot.quantity).to eq 0
      expect(snapshot.anchor_on).to eq Date.current
    end

    # 在庫 0 でも「購入推奨」にならない (次に使うのは半年後)
    it "ペースは 1/182・在庫切れ予測日は today + 182 で ok" do
      result = described_class.call(item.reload)

      expect(result.pace.per_day).to eq Rational(1, 182)
      expect(result.need_by_on).to eq Date.current + 182
      expect(result.days_left).to eq 182
      expect(result.status).to eq :ok
      expect(result.reason).to eq :pace
    end

    # 仕様 10 節の但し書き。使わないまま日が進むと 5 件目のイベントが上限 730 日の外へ出て、
    # 窓は (today - 730, today] の 4 件 / 730 日 になる (need_by_on は anchor + 183)
    it "使わないまま 162 日進むと soon、176 日進むと urgent になる" do
      item.reload

      expect(described_class.call(item, today: Date.current + 162).days_left).to eq 21
      expect(described_class.call(item, today: Date.current + 162).status).to eq :soon
      expect(described_class.call(item, today: Date.current + 176).days_left).to eq 7
      expect(described_class.call(item, today: Date.current + 176).status).to eq :urgent
    end
  end

  describe "検算例 3: 単 3 電池 (1 回に 2 本・20 日おき・在庫 5)" do
    let(:item) { create(:item, name: "単 3 電池", unit: "本") }

    before do
      # 0, 20, 40, 60, 80 日前に 2 本ずつ。最初の在庫イベントが 80 日前なので窓もそこで止まる
      record_usages(item, interval: 20, times: 5, quantity: 2)
      stock_up(item, 5)
    end

    it "u は 2・ペースは 1/10 になる" do
      snapshot = Forecast::SnapshotBuilder.call(item.reload)

      expect(snapshot.unit_usage).to eq 2
      expect(snapshot.consumed).to eq 8
      expect(snapshot.observed_days).to eq 80
      expect(snapshot.quantity).to eq 5
    end

    # 端数の 1 本は「次の交換 1 回分」に足りないので数えない
    it "在庫 5 本ではあと 2 回として anchor + 60 日が予測日になる" do
      result = described_class.call(item.reload)

      expect(result.pace.per_day).to eq Rational(1, 10)
      expect(result.need_by_on).to eq Date.current + 60
      expect(result.status).to eq :ok
    end
  end

  it "SnapshotBuilder と Calculator の合成になっている" do
    item = create(:item)
    stock_up(item, 5, days_ago: 40)
    record_usage(item, days_ago: 20)
    record_usage(item, days_ago: 2)
    item.reload

    expect(described_class.call(item))
      .to eq Forecast::Calculator.call(Forecast::SnapshotBuilder.call(item))
  end
end
