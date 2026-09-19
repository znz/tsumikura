class Store < ApplicationRecord
  # マスタの削除は nullify。購入の記録は消さず、店舗だけを外す
  # (docs/spec/01-domain-model.md 3 節)。DB 側の外部キーも on_delete: :nullify にしてある
  has_many :lots, dependent: :nullify

  # 店舗は position を持たない (docs/spec/01-domain-model.md 2 節) ので名前順に並べる
  scope :ordered, -> { order(:name, :id) }

  normalizes :name, with: Normalizations::STRIP

  validates :name, presence: true, length: { maximum: 50 }, uniqueness: true
end
