# FactoryBot の DSL (create / build / build_stubbed / attributes_for など) を
# 各 spec の中で明示的な module 参照なしに呼べるようにする
RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods
end
