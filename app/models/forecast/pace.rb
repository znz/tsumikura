module Forecast
  # 消費ペース (仕様 4 節)。per_day は 1 日あたりの消費量で、判定不能なら nil
  Pace = Data.define(:per_day, :event_count, :observed_days, :source) do
    # 仕様 4 節の表のとおり上から順に評価する
    def self.for(snapshot)
      case snapshot.mode
      when :none   then unknown(snapshot)
      when :manual then from_manual_interval(snapshot)
      when :auto   then from_records(snapshot)
      else
        # AR の enum を文字列や整数のまま渡すと黙って auto 扱いになり、
        # none の品目が在庫 0 で urgent になる (仕様 7 節違反)。気づけるように落とす
        raise ArgumentError, "estimation_mode は :auto / :manual / :none のいずれか (#{snapshot.mode.inspect})"
      end
    end

    def self.from_manual_interval(snapshot)
      # 起点 (anchor) が無いと予測日を出せないので、周期が分かっていても判定しない
      return unknown(snapshot) if snapshot.manual_interval_days.nil? || snapshot.anchor_on.nil?

      measured(snapshot, per_day: Rational(1, snapshot.manual_interval_days), source: :manual)
    end

    def self.from_records(snapshot)
      # anchor (起点) が無いと予測日を出せない。event_count はイベントの集計・anchor は
      # キャッシュ列なので、ずれると起点だけ欠けることがある。例外にせず判定不能にする
      return unknown(snapshot) if snapshot.anchor_on.nil?
      # 消費イベントが min_samples 件無いと間隔を 1 つも測れない
      return unknown(snapshot) if snapshot.event_count < snapshot.thresholds.min_samples
      # 観測が浅いと極端なペースが出る
      return unknown(snapshot) if snapshot.observed_days < snapshot.thresholds.min_observed_days

      # 誤差で切り上げが 1 日ずれないよう有理数で持つ
      measured(snapshot, per_day: Rational(snapshot.consumed, snapshot.observed_days), source: :auto)
    end

    def self.measured(snapshot, per_day:, source:)
      new(per_day: per_day, event_count: snapshot.event_count, observed_days: snapshot.observed_days, source: source)
    end

    def self.unknown(snapshot)
      new(per_day: nil, event_count: snapshot.event_count, observed_days: snapshot.observed_days, source: :unknown)
    end

    private_class_method :from_manual_interval, :from_records, :measured, :unknown

    def known?
      !per_day.nil?
    end
  end
end
