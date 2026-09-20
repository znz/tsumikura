# 通知セクションの表示 (docs/spec/03-screens.md 画面 11)。
module NotificationsHelper
  # user_agent から端末とブラウザを大まかに拾う。完全な判別は狙わない
  # (家族が「どの端末の行か」を見分けられれば足りる)。
  # 判定の順番に意味がある: Edge / Opera / Chrome は UA に Safari を含むので先に見る
  DEVICE_PATTERNS = {
    /iPhone/ => "iPhone",
    /iPad/ => "iPad",
    /Android/ => "Android",
    /Macintosh|Mac OS X/ => "Mac",
    /Windows/ => "Windows",
    /Linux/ => "Linux"
  }.freeze

  BROWSER_PATTERNS = {
    /Edg[A-Za-z]*\// => "Edge",
    /OPR\/|Opera/ => "Opera",
    /CriOS\/|Chrome\// => "Chrome",
    /FxiOS\/|Firefox\// => "Firefox",
    /Safari\// => "Safari"
  }.freeze

  UNKNOWN_DEVICE = "不明な端末".freeze

  def push_device_label(user_agent)
    return UNKNOWN_DEVICE if user_agent.blank?

    parts = [ match_pattern(DEVICE_PATTERNS, user_agent), match_pattern(BROWSER_PATTERNS, user_agent) ].compact
    parts.empty? ? UNKNOWN_DEVICE : parts.join(" / ")
  end

  # 日次ダイジェストを送る時刻 (画面の文言用。実際の実行時刻は config/recurring.yml)
  def digest_hour
    Rails.configuration.x.tsumikura.dig(:notifications, :digest_hour)
  end

  private
    def match_pattern(patterns, user_agent)
      patterns.each { |pattern, label| return label if user_agent.match?(pattern) }
      nil
    end
end
