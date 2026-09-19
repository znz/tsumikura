class Category < ApplicationRecord
  include Positioned

  # マスタの削除は nullify。品目は消さずカテゴリだけを外す (docs/spec/01-domain-model.md 3 節)。
  # DB 側の外部キーも on_delete: :nullify にしてある
  has_many :items, dependent: :nullify

  normalizes :name, with: Normalizations::STRIP

  validates :name, presence: true, length: { maximum: 50 }, uniqueness: true
end
