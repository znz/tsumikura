# パスキーの origin (docs/spec/05-auth.md 5 節) の正規化。
#
# WebAuthn の origin は **スキーム + ホスト + (非標準ポート)** でなければならない。
# `https://example.com/` のように末尾スラッシュが 1 つ付いているだけで、
# 認証器の ceremony は毎回静かに失敗する (画面には「パスキーでログインできませんでした」しか出ない)。
#
# また、空白や壊れた値を `URI.parse` に渡すと例外になる。初期化子の中で投げると
# **アプリが起動しなくなる**ので (「未設定でもパスキーだけが無効になる」方針に反する)、
# ここで nil に潰す。
#
# config/initializers/webauthn.rb から require_relative で読む。初期化子は
# オートロードより前に走るので、このファイルは config/application.rb の
# autoload_lib(ignore:) で Zeitwerk の管理から外してある。
module WebauthnOrigin
  ALLOWED_SCHEMES = %w[http https].freeze

  module_function

  # 正規化できない値 (nil / 空 / スキームなし / ホストなし / 壊れた URI) では nil を返す。
  # 呼び出し側は nil を「パスキーの設定なし」として扱う
  def normalize(value)
    uri = parse(value)
    return nil unless uri
    return nil unless ALLOWED_SCHEMES.include?(uri.scheme)
    return nil if uri.host.nil? || uri.host.empty?

    "#{uri.scheme}://#{uri.host}#{port_suffix(uri)}"
  end

  # RP ID は**ホスト名だけ**。origin から導くときはここを通す
  def host(value)
    parse(value)&.host.then { |h| h.nil? || h.empty? ? nil : h }
  end

  def parse(value)
    text = value.to_s.strip
    return nil if text.empty?

    URI.parse(text)
  rescue URI::InvalidURIError
    nil
  end

  def port_suffix(uri)
    return "" if uri.port.nil? || uri.port == uri.default_port

    ":#{uri.port}"
  end
end
