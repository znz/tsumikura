class StockMovement < ApplicationRecord
  # 在庫の唯一の真実 (docs/spec/01-domain-model.md 判断 1)。
  # lots.remaining_quantity / items.current_quantity はこのテーブルの総和のキャッシュにすぎない。
  belongs_to :item
  belongs_to :lot
  belongs_to :user
  # 「使った」操作 1 回に紐づく行。FEFO の分割で複数になるほか、在庫不足を補填した
  # 調整ロットの入庫 (正の adjustment) にも持たせる。記録を消すときに一緒に片づけるため
  belongs_to :usage_record, optional: true

  # prefix は必須。付けないと adjustment / usage などが AR のスコープ名と紛らわしくなる。
  # validate: true なので未知の値は例外ではなく検証エラーになる
  enum :kind, { purchase: 0, usage: 1, adjustment: 2, disposal: 3 }, prefix: true, validate: true
  # 廃棄理由は kind: disposal のときだけ入る (Phase 9)。nil を許すため allow_nil を明示する
  enum :disposal_reason, { expired: 0, damaged: 1, lost: 2, other: 3 },
    prefix: true, validate: { allow_nil: true }

  # 「消費」= 使用と棚卸のマイナス差分。廃棄は含まない (docs/spec/01-domain-model.md 2 節)。
  # 予測のアンカー (items.last_consumed_on) と消費ペースの分子はこの定義で数える
  scope :consumption, -> { kind_usage.or(kind_adjustment.where(quantity: ...0)) }

  # 0 の記録は在庫を動かさないので作らせない (DB 側にも check 制約がある)
  validates :quantity, numericality: {
    only_integer: true, other_than: 0,
    greater_than_or_equal_to: -Lot::MAX_QUANTITY, less_than_or_equal_to: Lot::MAX_QUANTITY
  }
  validates :occurred_on, presence: true
  # 廃棄理由は廃棄の記録にだけ入る (DB 側にも check 制約がある)
  validates :disposal_reason, absence: true, unless: :kind_disposal?
  validate :occurred_on_cannot_be_in_the_future
  validate :quantity_sign_must_match_kind
  validate :item_must_match_lot

  private
    # 消費イベントが必ず今日以前にあることを予測が前提にしている
    # (docs/spec/01-domain-model.md 2 節 / docs/spec/02-forecast.md)
    def occurred_on_cannot_be_in_the_future
      return if occurred_on.blank?

      errors.add(:occurred_on, :future) if occurred_on > Date.current
    end

    # 符号を取り違えると在庫が逆に動く。kind から符号を決められるものは固定する
    def quantity_sign_must_match_kind
      return if quantity.blank? || quantity.zero?

      case kind
      when "purchase" then errors.add(:quantity, :must_be_positive) if quantity.negative?
      when "usage", "disposal" then errors.add(:quantity, :must_be_negative) if quantity.positive?
      end
    end

    # item_id は集計のための非正規化。ロットとずれると在庫の合計が壊れる
    def item_must_match_lot
      return if lot.blank? || item_id.blank?

      errors.add(:item, :mismatched_lot) if item_id != lot.item_id
    end
end
