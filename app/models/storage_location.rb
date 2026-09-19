class StorageLocation < ApplicationRecord
  include Positioned

  # マスタの削除は nullify (docs/spec/01-domain-model.md 3 節)
  has_many :items, dependent: :nullify

  normalizes :name, with: Normalizations::STRIP

  validates :name, presence: true, length: { maximum: 50 }, uniqueness: true
end
