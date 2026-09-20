require_relative "forecast_helper"

RSpec.describe Forecast::Calculator do
  include ForecastSpecHelper

  describe "検算例 (仕様 10 節)" do
    it "例 1: トイレットペーパー — 在庫 3・u 1・ペース 1/5・anchor 2 日前なら need_by_on は today + 18 で soon" do
      result = described_class.call(
        snapshot(quantity: 3, unit_usage: 1, consumed: 18, observed_days: 90, event_count: 18, anchor_on: today - 2)
      )

      expect(result.pace.per_day).to eq Rational(1, 5)
      expect(result.need_by_on).to eq today + 18
      expect(result.days_left).to eq 18
      expect(result.status).to eq :soon
      expect(result.reason).to eq :pace
    end

    # 判定に使った在庫 (期限切れを除いた q) を Result に持たせる。
    # 買い物リスト (Phase 11) や画面が items.current_quantity を使うと期限切れのぶんだけずれる
    it "判定に使った在庫 (期限切れを除いた q) を Result に入れる" do
      expect(described_class.call(snapshot(quantity: 3)).quantity).to eq 3
      expect(described_class.call(snapshot(quantity: 0, minimum_quantity: 2)).quantity).to eq 0
    end

    it "例 2: くん煙剤 — 在庫 0・u 1・ペース 1/182・anchor today なら need_by_on は today + 182 で ok" do
      result = described_class.call(
        snapshot(quantity: 0, unit_usage: 1, consumed: 4, observed_days: 728, event_count: 5, anchor_on: today)
      )

      expect(result.pace.per_day).to eq Rational(1, 182)
      expect(result.need_by_on).to eq today + 182
      expect(result.days_left).to eq 182
      expect(result.status).to eq :ok
    end

    it "例 3: 単 3 電池 — 在庫 5・u 2・ペース 1/10 なら need_by_on は anchor + 60" do
      anchor_on = today - 5
      result = described_class.call(
        snapshot(quantity: 5, unit_usage: 2, consumed: 9, observed_days: 90, event_count: 5, anchor_on: anchor_on)
      )

      expect(result.pace.per_day).to eq Rational(1, 10)
      expect(result.need_by_on).to eq anchor_on + 60
    end
  end

  describe "在庫切れ予測日 (仕様 5 節)" do
    # ペース 1/5 (5 日に 1 回分) の品目
    def paced_snapshot(**overrides)
      snapshot(consumed: 18, observed_days: 90, event_count: 18, anchor_on: today, **overrides)
    end

    it "u が 2 のとき、在庫 5 は「あと 2 回」として計算される (端数の 1 は数えない)" do
      five = described_class.call(paced_snapshot(quantity: 5, unit_usage: 2))
      four = described_class.call(paced_snapshot(quantity: 4, unit_usage: 2))

      expect(five.need_by_on).to eq today + 30   # (2 + 1) 回 * 2 個 / (1/5)
      expect(five.need_by_on).to eq four.need_by_on
    end

    it "在庫が 1 回分に満たない (在庫 1・u 2) なら、在庫 0 と同じ need_by_on になる" do
      short = described_class.call(paced_snapshot(quantity: 1, unit_usage: 2))
      empty = described_class.call(paced_snapshot(quantity: 0, unit_usage: 2))

      expect(short.need_by_on).to eq today + 10  # (0 + 1) 回 * 2 個 / (1/5)
      expect(short.need_by_on).to eq empty.need_by_on
    end

    it "日数は切り上げる (ペース 4/729 なら 1 個あたり 183 日)" do
      result = described_class.call(
        snapshot(quantity: 0, unit_usage: 1, consumed: 4, observed_days: 729, event_count: 5, anchor_on: today)
      )

      expect(result.need_by_on).to eq today + 183  # 729 / 4 = 182.25 を切り上げ
    end

    it "在庫が Float でも「あと何回使えるか」は整数除算になる" do
      result = described_class.call(paced_snapshot(quantity: 5.0, unit_usage: 2))

      expect(result.need_by_on).to eq today + 30  # 2.5 回ではなく 2 回として計算する
    end

    it "ペースを有理数で持つので、浮動小数の誤差で切り上げが 1 日ずれない" do
      # 1 / (1/49) は Rational なら 49 ちょうど。Float だと 49.000000000000007 になり 50 に切り上がる
      result = described_class.call(
        snapshot(quantity: 0, unit_usage: 1, consumed: 1, observed_days: 49, event_count: 2, anchor_on: today)
      )

      expect(result.pace.per_day).to be_a Rational
      expect(result.need_by_on).to eq today + 49
    end

    it "need_by_on が過去になる場合は today に丸められ、days_left 0 で urgent になる" do
      result = described_class.call(paced_snapshot(quantity: 3, anchor_on: today - 100))

      expect(result.need_by_on).to eq today
      expect(result.days_left).to eq 0
      expect(result.status).to eq :urgent
    end
  end

  describe "3 段階の閾値 (仕様 6 節)" do
    # ペース 1 個/日・anchor が today なので days_left は 在庫 + 1 になる
    def result_for(quantity, thresholds: Forecast::Thresholds.default)
      described_class.call(
        snapshot(
          quantity: quantity, unit_usage: 1, consumed: 90, observed_days: 90, event_count: 91,
          anchor_on: today, thresholds: thresholds
        )
      )
    end

    it "days_left 7 は urgent" do
      expect(result_for(6)).to have_attributes(days_left: 7, status: :urgent)
    end

    it "days_left 8 は soon" do
      expect(result_for(7)).to have_attributes(days_left: 8, status: :soon)
    end

    it "days_left 21 は soon" do
      expect(result_for(20)).to have_attributes(days_left: 21, status: :soon)
    end

    it "days_left 22 は ok" do
      expect(result_for(21)).to have_attributes(days_left: 22, status: :ok)
    end

    it "品目固有の閾値 (soon 30 / urgent 10) が既定値の代わりに使われる" do
      custom = Forecast::Thresholds.default.with(soon_days: 30, urgent_days: 10)

      # days_left 9 は既定 (urgent 7) なら soon、上書き (urgent 10) なら urgent
      expect(result_for(8, thresholds: custom)).to have_attributes(days_left: 9, status: :urgent)
      expect(result_for(8)).to have_attributes(days_left: 9, status: :soon)

      # days_left 25 は既定 (soon 21) なら ok、上書き (soon 30) なら soon
      expect(result_for(24, thresholds: custom)).to have_attributes(days_left: 25, status: :soon)
      expect(result_for(24)).to have_attributes(days_left: 25, status: :ok)
    end
  end

  describe "最低在庫数による判定 (仕様 7 節)" do
    # ペース不明 (消費イベント 1 件) なので最低在庫数だけで決まる
    def result_for(quantity:, minimum_quantity: 3)
      described_class.call(snapshot(quantity: quantity, minimum_quantity: minimum_quantity, event_count: 1))
    end

    it "最低在庫 3・在庫 2 なら urgent" do
      expect(result_for(quantity: 2)).to have_attributes(status: :urgent, reason: :minimum)
    end

    it "最低在庫 3・在庫 3 なら soon (ちょうどならまだ切らしていない)" do
      expect(result_for(quantity: 3)).to have_attributes(status: :soon, reason: :minimum)
    end

    it "最低在庫 3・在庫 4 なら ok" do
      expect(result_for(quantity: 4)).to have_attributes(status: :ok, reason: :minimum)
    end

    it "ペース不明・最低在庫未設定・在庫ありなら unknown で reason は :no_data" do
      result = result_for(quantity: 4, minimum_quantity: nil)

      expect(result).to have_attributes(status: :unknown, reason: :no_data)
      expect(result.need_by_on).to be_nil
      expect(result.days_left).to be_nil
    end
  end

  describe "2 系統の合成 (仕様 7 節)" do
    it "ペース判定が ok でも最低在庫判定が urgent なら urgent で、reason は :minimum" do
      # ペース 1/5・在庫 20 個 (21 回分 = 105 日先) だが最低在庫 30 を下回っている
      result = described_class.call(
        snapshot(
          quantity: 20, minimum_quantity: 30, unit_usage: 1,
          consumed: 18, observed_days: 90, event_count: 18, anchor_on: today
        )
      )

      expect(result).to have_attributes(status: :urgent, reason: :minimum)
      expect(result.days_left).to eq 105
    end

    it "ペース判定が urgent で最低在庫判定が ok なら urgent で、reason は :pace" do
      result = described_class.call(
        snapshot(
          quantity: 1, minimum_quantity: 1, unit_usage: 1,
          consumed: 90, observed_days: 90, event_count: 91, anchor_on: today - 5
        )
      )

      expect(result).to have_attributes(status: :urgent, reason: :pace, days_left: 0)
    end

    it "ペース判定も最低在庫判定も soon なら、reason は :minimum を優先する" do
      # 在庫 3 = 最低在庫 3 で soon、ペース 1/5・anchor 2 日前でも days_left 18 で soon
      result = described_class.call(
        snapshot(
          quantity: 3, minimum_quantity: 3, unit_usage: 1,
          consumed: 18, observed_days: 90, event_count: 18, anchor_on: today - 2
        )
      )

      expect(result).to have_attributes(status: :soon, reason: :minimum, days_left: 18)
    end

    it "ペース判定が ok で最低在庫判定が soon なら soon で、reason は :minimum" do
      result = described_class.call(
        snapshot(
          quantity: 5, minimum_quantity: 5, unit_usage: 1,
          consumed: 18, observed_days: 90, event_count: 18, anchor_on: today
        )
      )

      expect(result).to have_attributes(status: :soon, reason: :minimum, days_left: 30)
    end

    it "ペース判定が soon で最低在庫判定が ok なら soon で、reason は :pace" do
      result = described_class.call(
        snapshot(
          quantity: 3, minimum_quantity: 2, unit_usage: 1,
          consumed: 18, observed_days: 90, event_count: 18, anchor_on: today
        )
      )

      expect(result).to have_attributes(status: :soon, reason: :pace, days_left: 20)
    end

    it "ペースが分かっていれば reason が :minimum でも need_by_on と days_left を返す" do
      result = described_class.call(
        snapshot(
          quantity: 20, minimum_quantity: 30, unit_usage: 1,
          consumed: 18, observed_days: 90, event_count: 18, anchor_on: today
        )
      )

      expect(result.need_by_on).to eq today + 105
    end
  end

  describe "在庫 0 (仕様 7 節 / 9 節)" do
    it "ペース不明で在庫 0 なら urgent で、reason は :out_of_stock" do
      result = described_class.call(snapshot(quantity: 0, event_count: 1))

      expect(result).to have_attributes(status: :urgent, reason: :out_of_stock)
      expect(result.need_by_on).to be_nil
    end

    it "ペース不明・在庫 0・最低在庫 3 のときは reason に :out_of_stock を優先する" do
      result = described_class.call(snapshot(quantity: 0, minimum_quantity: 3, event_count: 1))

      expect(result).to have_attributes(status: :urgent, reason: :out_of_stock)
    end

    it "在庫 0 でもペースが分かっていれば式どおりに判定する (urgent 固定にしない)" do
      result = described_class.call(
        snapshot(quantity: 0, unit_usage: 1, consumed: 4, observed_days: 728, event_count: 5, anchor_on: today)
      )

      expect(result).to have_attributes(status: :ok, reason: :pace)
    end

    it "manual モードでも anchor が無ければペース不明なので、在庫 0 は urgent になる" do
      result = described_class.call(snapshot(quantity: 0, mode: :manual, manual_interval_days: 182, anchor_on: nil))

      expect(result).to have_attributes(status: :urgent, reason: :out_of_stock)
    end
  end

  describe "none モード (仕様 8 節)" do
    it "在庫 0 でも urgent にせず、最低在庫未設定なら unknown になる" do
      result = described_class.call(snapshot(quantity: 0, mode: :none, event_count: 18, observed_days: 90, consumed: 18))

      expect(result).to have_attributes(status: :unknown, reason: :no_data)
    end

    it "最低在庫数が設定されていれば、それだけで判定する" do
      result = described_class.call(snapshot(quantity: 0, minimum_quantity: 1, mode: :none))

      expect(result).to have_attributes(status: :urgent, reason: :minimum)
    end

    it "在庫と最低在庫が同数なら soon になる" do
      result = described_class.call(snapshot(quantity: 2, minimum_quantity: 2, mode: :none))

      expect(result).to have_attributes(status: :soon, reason: :minimum)
    end
  end

  describe "manual モード (仕様 8 節)" do
    it "実績が無くても manual_interval_days から need_by_on を出す" do
      # 182 日に 1 個・在庫 1 個 (使用中の 1 個と合わせて 2 回分) を今日買ったところ
      result = described_class.call(
        snapshot(quantity: 1, unit_usage: 1, mode: :manual, manual_interval_days: 182, anchor_on: today)
      )

      expect(result.pace.source).to eq :manual
      expect(result.need_by_on).to eq today + 364
      expect(result.status).to eq :ok
    end

    it "manual_interval_days は「1 単位を何日で使うか」なので、u が 2 でもペースは 1/5 のまま" do
      # 在庫 4・u 2 で残り 2 回。(2 + 1) 回 * 2 個 / (1/5) = 30 日
      result = described_class.call(
        snapshot(quantity: 4, unit_usage: 2, mode: :manual, manual_interval_days: 5, anchor_on: today)
      )

      expect(result.pace.per_day).to eq Rational(1, 5)
      expect(result.need_by_on).to eq today + 30
    end

    it "在庫 0 でもペースが分かっていれば reason は :pace (:out_of_stock にしない)" do
      result = described_class.call(
        snapshot(quantity: 0, unit_usage: 1, mode: :manual, manual_interval_days: 182, anchor_on: today)
      )

      expect(result).to have_attributes(status: :ok, reason: :pace, days_left: 182)
    end

    it "anchor が古い tracking_started_on のときは need_by_on が today に丸められる" do
      result = described_class.call(
        snapshot(quantity: 0, unit_usage: 1, mode: :manual, manual_interval_days: 182, anchor_on: today - 400)
      )

      expect(result).to have_attributes(status: :urgent, reason: :pace, days_left: 0)
      expect(result.need_by_on).to eq today
    end
  end

  describe "エッジケース (仕様 9 節)" do
    it "2 年以上使っていない品目は窓に消費イベントが入らないので unknown になり、最低在庫数だけで判定する" do
      result = described_class.call(snapshot(quantity: 1, minimum_quantity: 2, event_count: 0, observed_days: 730))

      expect(result).to have_attributes(status: :urgent, reason: :minimum)
      expect(result.pace).not_to be_known
    end

    it "anchor_on が nil (キャッシュずれ) でも例外にならず unknown になる" do
      result = described_class.call(snapshot(quantity: 1, consumed: 18, observed_days: 90, event_count: 18, anchor_on: nil))

      expect(result).to have_attributes(status: :unknown, reason: :no_data)
      expect(result.need_by_on).to be_nil
    end

    it "登録初日に大量使用しても観測日数が足りないので極端なペースは出ない" do
      result = described_class.call(snapshot(quantity: 1, consumed: 20, event_count: 2, observed_days: 0))

      expect(result.pace).not_to be_known
      expect(result).to have_attributes(status: :unknown, reason: :no_data)
    end
  end
end
