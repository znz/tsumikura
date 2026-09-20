# WebAuthn の challenge の受け渡し (docs/spec/05-auth.md 5 節)。
#
# **セッションは CookieStore なので `session.delete` だけでは 1 回限りにならない。**
# delete は「次に返す Cookie から消す」だけで、challenge を含む**古い Cookie は
# サーバから見ると永久に有効**なまま。古い Cookie と assertion の組を持ち出されると、
# sign_count を常に 0 で返す同期型のパスキー (iCloud / Google) では何度でもログインできてしまう。
# また、生体認証をキャンセルすると登録用の challenge がセッションに残り続け、
# その Cookie を盗んだ者がパスワードの再確認なしで自分の認証器を登録できてしまう。
#
# そこで 1 回限りを 2 つで担保する:
#   1. **有効期限**  challenge と一緒に発行時刻を入れ、期限を過ぎたものは使わない
#   2. **サーバ側の消費記録**  使おうとした時点で Rails.cache に印を付け、2 回目は断る
#      (成功・失敗にかかわらず消費する)
module WebauthnChallenge
  extend ActiveSupport::Concern

  CONSUMED_CACHE_PREFIX = "webauthn-challenge:".freeze

  private
    def issue_webauthn_challenge(key, challenge)
      session[key] = { "value" => challenge, "issued_at" => Time.current.to_i }

      challenge
    end

    # 取り出した時点で使い切る。使えないときは nil を返し、呼び出し側は
    # そのまま verify に渡して失敗させる (nil は InvalidChallengeError になる)
    def consume_webauthn_challenge(key, ttl)
      stored = session.delete(key)
      # 古い形式 (文字列だけ) のセッションが残っていても受け付けない
      return nil unless stored.is_a?(Hash)

      value = stored["value"]
      issued_at = stored["issued_at"]
      return nil unless value.is_a?(String) && issued_at.is_a?(Integer)
      return nil if Time.current.to_i - issued_at > ttl.to_i
      return nil unless claim_webauthn_challenge(value, ttl)

      value
    end

    # 未使用なら印を付けて true、すでに使われていれば false。
    # challenge そのものはログにもキャッシュにも置かず、ダイジェストだけを残す
    def claim_webauthn_challenge(value, ttl)
      digest = OpenSSL::Digest::SHA256.hexdigest(value)

      Rails.cache.write("#{CONSUMED_CACHE_PREFIX}#{digest}", true, unless_exist: true, expires_in: ttl)
    end
end
