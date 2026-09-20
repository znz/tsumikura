# 予測 (Forecast) と期限 (Expiry) の表示 (docs/spec/03-screens.md ステータスの見せ方)。
#
# バッジは**色だけに頼らず必ず文言を出す**。ok はバッジを出さず、unknown は「—」にする。
module ForecastHelper
  # ペースを「約 2.3 個 / 月」と出すときの 1 か月。表示専用で、判定は 1 日あたりの Rational
  PACE_MONTH_DAYS = 30

  FORECAST_BADGE_CLASSES = {
    urgent: "bg-red-100 text-red-800",
    soon: "bg-amber-100 text-amber-900",
    ok: "bg-slate-100 text-slate-600",
    unknown: "text-slate-400"
  }.freeze

  EXPIRY_BADGE_CLASSES = {
    expired: "bg-red-100 text-red-800",
    expiring_soon: "bg-amber-100 text-amber-900",
    fresh: "bg-slate-100 text-slate-600"
  }.freeze

  def forecast_status_label(status)
    t("forecast.status.#{status}")
  end

  def expiry_status_label(status)
    t("expiry.status.#{status}")
  end

  def forecast_badge_classes(status)
    class_names("inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
      FORECAST_BADGE_CLASSES.fetch(status))
  end

  def expiry_badge_classes(status)
    class_names("inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
      EXPIRY_BADGE_CLASSES.fetch(status))
  end

  # 「あと 18 日」。当日 (0 日) は「あと 0 日」だと切迫感が伝わらないので言葉にする
  def forecast_days_left_text(forecast)
    forecast.days_left.zero? ? "今日まで" : "あと #{forecast.days_left} 日"
  end

  # 在庫が残っているのに予測日が today に丸められた状態 (仕様 9 節「need_by_on が過去」)。
  # 「在庫 5 なのに在庫切れ予測日が今日」は誤解を生むので、そのまま出さず理由を添える
  def forecast_overdue?(forecast)
    forecast.days_left&.zero? && forecast.quantity.positive?
  end

  # 「約 2.3 個 / 月」。月に 1 個も使わない品目は「約 182 日に 1 個」の方が読みやすい
  def forecast_pace_text(pace, unit)
    return nil unless pace.known?

    per_month = pace.per_day * PACE_MONTH_DAYS
    return "約 #{format('%.1f', per_month)} #{unit} / 月" if per_month >= 1

    "約 #{(1 / pace.per_day).round} 日に 1 #{unit}"
  end

  # 判定の理由 (docs/spec/02-forecast.md 7 節)。どの判定を採ったのかを言葉にする。
  # :no_data (何も判定できていない) のときは nil で、代わりに forecast_unknown_text を出す
  def forecast_reason_text(item, forecast)
    case forecast.reason
    when :pace then "消費ペースから判定しました。"
    when :minimum then "最低在庫数 (#{item.minimum_quantity} #{item.unit}) との比較で判定しました。"
    when :out_of_stock then "在庫が 0 で、消費ペースがまだ分かりません。"
    end
  end

  # unknown のときに「何がたまれば予測が始まるか」を伝える
  # (docs/spec/03-screens.md ステータスの見せ方: 不安にさせない)。
  # Pace には unknown でも event_count / observed_days が入っているので、そこから理由を選ぶ
  def forecast_unknown_text(item, forecast)
    thresholds = Forecast::Thresholds.default

    if item.estimation_mode_none?
      "予測しない設定です。"
    elsif item.estimation_mode_manual? && item.manual_interval_days.blank?
      # 「手動」は使用間隔が必須 (Phase 6) なので、ふつうはここに来ない
      "使用間隔を設定すると予測を始めます。"
    elsif item.tracking_started_on.nil?
      # 在庫イベントが 1 件も無い = 起点 (anchor) が無い
      "在庫を登録すると予測を始めます。"
    elsif forecast.pace.event_count < thresholds.min_samples
      # 同じ日に何度記録しても消費イベントは 1 件なので「別の日に」と書く (仕様 2 節)
      "使用の記録が別の日に #{thresholds.min_samples} 回たまると予測を始めます。"
    elsif forecast.pace.observed_days < thresholds.min_observed_days
      # 「あと n 日」とは書けない。窓の両端が消費イベント日のときは日が経っても
      # observed_days が増えず、いつまでも同じ日数を言い続けてしまう
      "観測期間がまだ短いため、次の使用の記録から予測を始めます。"
    else
      "データ収集中 — 使用記録がたまると予測を開始します。"
    end
  end
end
