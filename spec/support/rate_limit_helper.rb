# rate_limit は Rails.cache に increment を打つ (ActionController::RateLimiting)。
# test 環境の cache_store は null_store なので実際に 429 にはできないが、
# 「対象アクションに rate_limit が宣言されていること」はキーの有無で守れる。
module RateLimitHelper
  def rate_limit_keys
    keys = []
    allow(Rails.cache).to receive(:increment).and_wrap_original do |original, key, *args, **options|
      keys << key
      original.call(key, *args, **options)
    end
    yield
    keys
  end
end

RSpec.configure do |config|
  config.include RateLimitHelper, type: :request
end
