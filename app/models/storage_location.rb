class StorageLocation < ApplicationRecord
  include Positioned

  # マスタの削除は nullify (docs/spec/01-domain-model.md 3 節)。
  # 保管場所を消した棚卸は「すべての保管場所」を対象にした記録として残る
  has_many :items, dependent: :nullify
  has_many :stock_takes, dependent: :nullify

  normalizes :name, with: Normalizations::STRIP

  validates :name, presence: true, length: { maximum: 50 }, uniqueness: true
end
