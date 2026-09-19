require_relative "forecast_helper"

RSpec.describe Forecast::Window do
  include ForecastSpecHelper

  # 引数を省略したときは「消費イベントも在庫イベントも無い」品目とする
  def window_for(nth_event_on: nil, last_event_on: nil, tracking_started_on: nil,
                 thresholds: Forecast::Thresholds.default)
    described_class.for(
      today: today,
      nth_event_on: nth_event_on,
      last_event_on: last_event_on,
      tracking_started_on: tracking_started_on,
      thresholds: thresholds
    )
  end

  it "消費イベントが十分あるとき (5 件目が 22 日前) は、窓の開始が today - 90 日・終わりが today になる" do
    window = window_for(nth_event_on: today - 22, last_event_on: today - 2, tracking_started_on: today - 400)

    expect(window.start_on).to eq today - 90
    expect(window.end_on).to eq today
  end

  it "消費イベントが 1 件も無いときは、窓の開始が today - 90 日になる" do
    window = window_for(nth_event_on: nil, last_event_on: nil, tracking_started_on: today - 400)

    expect(window.start_on).to eq today - 90
    expect(window.end_on).to eq today
  end

  it "5 件目の消費イベントが 200 日前なら、窓の開始は 200 日前まで伸びる" do
    window = window_for(nth_event_on: today - 200, last_event_on: today - 3, tracking_started_on: today - 400)

    expect(window.start_on).to eq today - 200
  end

  it "消費イベントが 3 件しかなければ、最古の消費イベント日 (nth_event_on) まで伸びる" do
    # 呼び出し側は window_events 件に満たないとき最古の消費イベント日を nth_event_on に渡す
    window = window_for(nth_event_on: today - 150, last_event_on: today - 10, tracking_started_on: today - 400)

    expect(window.start_on).to eq today - 150
  end

  it "tracking_started_on が 30 日前なら、窓の開始は 30 日前で止まる" do
    window = window_for(nth_event_on: today - 20, last_event_on: today - 1, tracking_started_on: today - 30)

    expect(window.start_on).to eq today - 30
  end

  it "5 件目の消費イベントが 900 日前でも、窓の開始は today - 730 日で止まる" do
    window = window_for(nth_event_on: today - 900, last_event_on: today - 5, tracking_started_on: today - 1000)

    expect(window.start_on).to eq today - 730
  end

  it "tracking_started_on が nil なら、下限は today - 730 日だけになる" do
    window = window_for(nth_event_on: today - 900, last_event_on: today - 5, tracking_started_on: nil)

    expect(window.start_on).to eq today - 730
  end

  describe "窓の長さの境界" do
    it "5 件目の消費イベントが 89 日前なら、窓は最低の長さ (today - 90 日) のままになる" do
      window = window_for(nth_event_on: today - 89, last_event_on: today - 1, tracking_started_on: today - 400)

      expect(window.start_on).to eq today - 90
    end

    it "5 件目の消費イベントが 91 日前なら、窓はそこまで伸びる" do
      window = window_for(nth_event_on: today - 91, last_event_on: today - 1, tracking_started_on: today - 400)

      expect(window.start_on).to eq today - 91
    end

    it "5 件目の消費イベントがちょうど 730 日前なら、窓の開始はその日になる" do
      window = window_for(nth_event_on: today - 730, last_event_on: today, tracking_started_on: today - 1000)

      expect(window.start_on).to eq today - 730
    end

    it "window_min_days は渡された閾値を見る (30 なら窓の最低の長さは today - 30 日)" do
      thresholds = Forecast::Thresholds.default.with(window_min_days: 30)
      window = window_for(nth_event_on: today - 10, last_event_on: today - 1, thresholds: thresholds)

      expect(window.start_on).to eq today - 30
    end

    it "window_max_days は渡された閾値を見る (365 なら下限は today - 365 日)" do
      thresholds = Forecast::Thresholds.default.with(window_max_days: 365)
      window = window_for(nth_event_on: today - 900, last_event_on: today - 5, thresholds: thresholds)

      expect(window.start_on).to eq today - 365
    end

    it "5 件目の消費イベントが 731 日前なら、窓の開始は today - 730 日になる" do
      window = window_for(nth_event_on: today - 731, last_event_on: today, tracking_started_on: today - 1000)

      expect(window.start_on).to eq today - 730
    end
  end

  describe "窓の終わり" do
    it "窓の開始が nth_event_on と一致するときは、終わりが last_event_on (anchor) になる" do
      # 完結した間隔だけでペースを測るため、両端とも消費イベント日に揃える
      window = window_for(nth_event_on: today - 200, last_event_on: today - 10, tracking_started_on: today - 400)

      expect(window.start_on).to eq today - 200
      expect(window.end_on).to eq today - 10
    end

    it "窓の開始が today - 90 日で決まったときは、終わりは today になる" do
      window = window_for(nth_event_on: today - 22, last_event_on: today - 2, tracking_started_on: today - 400)

      expect(window.end_on).to eq today
    end

    it "窓の開始が下限 (tracking_started_on) で決まったときは、終わりは today になる" do
      window = window_for(nth_event_on: today - 200, last_event_on: today - 10, tracking_started_on: today - 100)

      expect(window.start_on).to eq today - 100
      expect(window.end_on).to eq today
    end

    it "5 件目の消費イベントがちょうど today - 90 日なら、開始日が消費イベント日なので終わりは last_event_on になる" do
      window = window_for(nth_event_on: today - 90, last_event_on: today - 3, tracking_started_on: today - 400)

      expect(window.start_on).to eq today - 90
      expect(window.end_on).to eq today - 3
    end

    it "5 件目の消費イベントがちょうど 730 日前なら、終わりは last_event_on になる" do
      window = window_for(nth_event_on: today - 730, last_event_on: today - 10, tracking_started_on: today - 1000)

      expect(window.start_on).to eq today - 730
      expect(window.end_on).to eq today - 10
    end

    it "nth_event_on と tracking_started_on が同じ日なら、終わりは last_event_on になる" do
      window = window_for(nth_event_on: today - 200, last_event_on: today - 10, tracking_started_on: today - 200)

      expect(window.start_on).to eq today - 200
      expect(window.end_on).to eq today - 10
    end

    it "窓の開始が下限 (today - 730 日) で決まったときは、終わりは today になる" do
      window = window_for(nth_event_on: today - 900, last_event_on: today - 10, tracking_started_on: nil)

      expect(window.start_on).to eq today - 730
      expect(window.end_on).to eq today
    end
  end

  describe "#observed_days" do
    it "窓の終わり - 窓の開始 (+1 しない)" do
      window = window_for(nth_event_on: today - 22, last_event_on: today - 2, tracking_started_on: today - 400)

      expect(window.observed_days).to eq 90
    end

    it "検算例 2: イベントが today / 182 / 364 / 546 / 728 日前なら、開始 728 日前・終わり today・observed_days 728" do
      window = window_for(nth_event_on: today - 728, last_event_on: today, tracking_started_on: today - 800)

      expect(window.start_on).to eq today - 728
      expect(window.end_on).to eq today
      expect(window.observed_days).to eq 728
    end
  end
end
