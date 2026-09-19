class Store < ApplicationRecord
  # 店舗は position を持たない (docs/spec/01-domain-model.md 2 節) ので名前順に並べる。
  # 参照元の lots は Phase 7 で追加する (そこで dependent: :nullify を付ける)
  scope :ordered, -> { order(:name, :id) }

  normalizes :name, with: Normalizations::STRIP

  validates :name, presence: true, length: { maximum: 50 }, uniqueness: true
end
