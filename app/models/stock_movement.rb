class StockMovement < ApplicationRecord
  # 在庫の唯一の真実 (docs/spec/01-domain-model.md 判断 1)。
  # lots.remaining_quantity / items.current_quantity はこのテーブルの総和のキャッシュにすぎない。
  belongs_to :item
  belongs_to :lot
  belongs_to :user
  # 「使った」操作 1 回に紐づく行。FEFO の分割で複数になるほか、在庫不足を補填した
  # 調整ロットの入庫 (正の adjustment) にも持たせる。記録を消すときに一緒に片づけるため
  belongs_to :usage_record, optional: true
  # 棚卸の確定で作られる調整の行 (マイナス差分の出庫 / プラス差分の入庫)。
  # 差分と movements の合計が一致していることは rake stock:verify が見張る
  belongs_to :stock_take_entry, optional: true

  # prefix は必須。付けないと adjustment / usage などが AR のスコープ名と紛らわしくなる。
  # validate: true なので未知の値は例外ではなく検証エラーになる
  enum :kind, { purchase: 0, usage: 1, adjustment: 2, disposal: 3 }, prefix: true, validate: true
  # 廃棄理由は kind: disposal のときだけ入る (Phase 9)。nil を許すため allow_nil を明示する
  enum :disposal_reason, { expired: 0, damaged: 1, lost: 2, other: 3 },
    prefix: true, validate: { allow_nil: true }

  # 「消費」= 使用と棚卸のマイナス差分。廃棄は含まない (docs/spec/01-domain-model.md 2 節)。
  # 予測のアンカー (items.last_consumed_on) と消費ペースの分子はこの定義で数える
  scope :consumption, -> { kind_usage.or(kind_adjustment.where(quantity: ...0)) }

  # 品目詳細の「最近の記録」に出す行。使用と購入は UsageRecord / Lot 側から拾うので、
  # ここでは廃棄と棚卸の調整だけを見る (在庫不足の補填は操作ではないので出さない)
  scope :recorded_adjustments, -> { kind_adjustment.where.not(stock_take_entry_id: nil) }
  # 新しい記録から順に。同じ日なら後から記録したものを新しいとみなす
  scope :recent_first, -> { order(occurred_on: :desc, id: :desc) }

  # 0 の記録は在庫を動かさないので作らせない (DB 側にも check 制約がある)
  validates :quantity, numericality: {
    only_integer: true, other_than: 0,
    greater_than_or_equal_to: -Lot::MAX_QUANTITY, less_than_or_equal_to: Lot::MAX_QUANTITY
  }
  validates :occurred_on, presence: true
  # 廃棄理由は廃棄の記録にだけ入り、廃棄には必ず入る (DB 側にも check 制約がある)。
  # 理由の無い廃棄は「なんとなく減った」を廃棄で片づけた記録になり、
  # あとから何が起きたのか分からなくなる
  validates :disposal_reason, absence: true, unless: :kind_disposal?
  validates :disposal_reason, presence: true, if: :kind_disposal?
  validate :occurred_on_cannot_be_in_the_future
  validate :quantity_sign_must_match_kind
  validate :item_must_match_lot

  # 「最近の記録」で使用記録 (UsageRecord) や購入 (Lot) と時系列に混ぜるための共通の日付
  def recorded_on
    occurred_on
  end

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
