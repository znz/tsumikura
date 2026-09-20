module Forecast
  # Snapshot から要購入判定を出す純粋関数 (仕様 5〜7 節)
  module Calculator
    RANK = { unknown: -1, ok: 0, soon: 1, urgent: 2 }.freeze

    module_function

    def call(snapshot)
      pace = Pace.for(snapshot)
      need_by_on = need_by_on_for(snapshot, pace)
      days_left = need_by_on && (need_by_on - snapshot.today).to_i

      # 2 系統の判定の悪い方を採用する。reason は同順位のときの優先順に並べたキーから拾う
      judgements = {
        out_of_stock: by_stockout(snapshot, pace),
        minimum: by_minimum(snapshot),
        pace: days_left && by_pace(snapshot, days_left)
      }.compact
      status = judgements.values.max_by { RANK.fetch(_1) } || :unknown

      Result.new(
        status: status,
        pace: pace,
        need_by_on: need_by_on,
        days_left: days_left,
        reason: judgements.key(status) || :no_data,
        # 判定に使った在庫 (期限切れを除く)。画面と買い物リストが同じ数を出せるように持たせる
        quantity: snapshot.quantity
      )
    end

    # 「次に使いたいときに未使用在庫が無い日」(仕様 5 節)。
    # 使用中の 1 個は在庫に入っていないので uses_left + 1 回分先を見る
    def need_by_on_for(snapshot, pace)
      return nil unless pace.known?

      # div で整数除算にする。Float や BigDecimal が来ても「まるごと何回分か」で数える
      uses_left = snapshot.quantity.div(snapshot.unit_usage)
      need_by_on = snapshot.anchor_on + ((uses_left + 1) * snapshot.unit_usage / pace.per_day).ceil
      [ need_by_on, snapshot.today ].max
    end

    # ペースが分からないまま在庫が尽きたら知らせる。
    # none は「予測させない」という意思表示なので適用しない (仕様 7 節)
    def by_stockout(snapshot, pace)
      :urgent if snapshot.mode != :none && !pace.known? && snapshot.quantity <= 0
    end

    # 「最低在庫数 = 切らしたくない数」なので、ちょうどではまだ切らしていない
    def by_minimum(snapshot)
      return nil if snapshot.minimum_quantity.nil?

      if snapshot.quantity < snapshot.minimum_quantity then :urgent
      elsif snapshot.quantity == snapshot.minimum_quantity then :soon
      else :ok
      end
    end

    def by_pace(snapshot, days_left)
      if days_left <= snapshot.thresholds.urgent_days then :urgent
      elsif days_left <= snapshot.thresholds.soon_days then :soon
      else :ok
      end
    end

    private_class_method :need_by_on_for, :by_stockout, :by_minimum, :by_pace
  end
end
