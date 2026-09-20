# test の cache_store は :null_store (config/environments/test.rb) なので、
# 「一度書いたら二度目は書けない」(unless_exist) を試せない。
# WebAuthn の challenge の消費記録 (app/controllers/concerns/webauthn_challenge.rb) のように
# **キャッシュに覚えることが仕様そのもの**の spec だけ、MemoryStore に差し替える。
#
# rate_limit が使うのは ActionController::Base.cache_store (起動時に決まる別オブジェクト) なので、
# ここを差し替えても回数制限には影響しない。
RSpec.configure do |config|
  config.around(:each, :memory_cache) do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    begin
      example.run
    ensure
      Rails.cache = original
    end
  end
end
