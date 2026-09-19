# 並べ替えできるマスタ (カテゴリ・保管場所) と、品目ごとの用途の position を面倒みる。
# 家庭で使う数の想定なので、凝った隙間確保はせず「毎回 1 から振り直す」ことで
# position の重複や欠番があっても壊れないようにする。
module Positioned
  extend ActiveSupport::Concern

  DIRECTIONS = %w[ up down ].freeze

  included do
    scope :ordered, -> { order(:position, :id) }

    before_create :assign_next_position
  end

  # 1 つ上 (:up) / 1 つ下 (:down) と入れ替える。端まで来ていたら何もせず false。
  # 「最近編集した」の表示を壊さないよう、updated_at は汚さない (update_column)。
  def move!(direction)
    return false unless DIRECTIONS.include?(direction.to_s)

    records = positioned_siblings.ordered.to_a
    from = records.index { |record| record.id == id }
    return false if from.nil?

    to = direction.to_s == "up" ? from - 1 : from + 1
    return false if to.negative? || to >= records.size

    records[from], records[to] = records[to], records[from]
    renumber(records)
    true
  end

  private
    # 並べ替えの範囲。既定はテーブル全体だが、品目ごとの用途 (ItemPurpose) のように
    # 親の中だけで並べ替えるモデルはここを上書きする。
    # 画面に出ない行 (アーカイブ済みなど) を含めると、「上へ」が見えない行と
    # 入れ替わって画面が変わらないので、範囲は画面の一覧とそろえる
    def positioned_siblings
      self.class.all
    end

    # 採番の範囲。並べ替えの範囲から外れている行とも position が重ならないようにする
    def positioned_numbering_scope
      positioned_siblings
    end

    def renumber(records)
      self.class.transaction do
        records.each_with_index do |record, index|
          record.update_column(:position, index + 1) unless record.position == index + 1
        end
      end
    end

    def assign_next_position
      self.position = next_position if position.to_i.zero?
    end

    # 末尾の position。自分自身は数えない (復帰させるときにも使う)
    def next_position
      scope = positioned_numbering_scope
      scope = scope.where.not(id: id) if persisted?

      (scope.maximum(:position) || 0) + 1
    end
end
