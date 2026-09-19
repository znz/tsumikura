require "yaml"

module Forecast
  # 予測の閾値 (仕様 11 節)。
  # 既定値の正は config/tsumikura.yml (仕様 13 節) なので、Rails を起動しない spec でも
  # 同じ値になるよう Rails.configuration ではなく標準の YAML で直接読む。
  Thresholds = Data.define(
    :soon_days, :urgent_days,
    :window_min_days, :window_events, :window_max_days,
    :min_samples, :min_observed_days
  ) do
    # 設定ミスに気づけるように、ペースの前提 (仕様 4 節) をここで守る。
    # min_samples 1 だと 1 件で間隔が測れたことになり、min_observed_days 0 だとゼロ除算になる
    def initialize(**attrs)
      super
      raise ArgumentError, "min_samples は 2 以上にする (#{min_samples})" if min_samples < 2
      raise ArgumentError, "min_observed_days は 1 以上にする (#{min_observed_days})" if min_observed_days < 1
    end

    def self.default
      @default ||= from_config(YAML.safe_load_file(config_path).fetch("shared").fetch("forecast"))
    end

    # Data.define のブロック内で定数を置くと Forecast 直下に定義されてしまうのでメソッドにする
    def self.config_path
      File.expand_path("../../../config/tsumikura.yml", __dir__)
    end

    def self.from_config(config)
      new(**members.to_h { |key| [ key, config.fetch(key.to_s) ] })
    end

    private_class_method :config_path, :from_config
  end
end
