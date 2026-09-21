# 主キーは UUIDv7 なので「最大値 + 1」のような『存在しない id』が作れない
# (docs/spec/01-domain-model.md 2 節)。代わりに無作為な UUID / Base58 を使う。
module UuidHelper
  # DB にあるはずのない id (UUID)。モデルや POST の本文で使う
  def nonexistent_uuid
    SecureRandom.uuid
  end

  # URL に入れる「存在しない id」(Base58 の 22 文字)。形は正しいが引けない
  def nonexistent_param
    Base58Uuid.encode(SecureRandom.uuid)
  end

  # Base58 として読めない値 (長さ違い・アルファベット外の文字)。
  # 500 ではなく 404 になることを確かめるために使う
  def malformed_param
    "0" * 22   # "0" は Base58 のアルファベットに無い
  end
end

RSpec.configure do |config|
  config.include UuidHelper
end
