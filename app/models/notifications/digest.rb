module Notifications
  # 日次ダイジェストの「悪化した品目」の抽出と本文の組み立て
  # (docs/spec/04-notifications.md 4 節)。
  #
  # 予測 (Forecast)・期限判定 (Expiry) と同じく、ここは DB にも Rails にも依存しない
  # 純粋関数にする (spec_helper だけで回せる)。突き合わせるのは **status だけ**で、
  # days_left は見ない (毎日 1 ずつ動くので、差分で通知すると毎朝鳴る)。
  # status は文字列で比べる (docs/spec/02-forecast.md 14 節)。
  module Digest
    # 悪化の向きは画面と同じ順位表から取る (2 か所に順位を書かない)
    PURCHASE_RANK = Forecast::Calculator::RANK.transform_keys(&:to_s).freeze
    EXPIRY_RANK = Expiry::Status::RANK.transform_keys(&:to_s).freeze

    # item_alert_states に行が無い品目の前回値 (= まだ何も知らせていない)
    UNKNOWN_PURCHASE = "unknown".freeze
    FRESH_EXPIRY = "fresh".freeze

    # 「今の値がこれなら知らせてよい」。ok / unknown / fresh は、悪化していても知らせない
    # (unknown は判定できていないだけなので不安を煽らない)。
    # 並びは本文に出す順 (悪いほうが先) でもある
    PURCHASE_ALERTS = %w[ urgent soon ].freeze
    EXPIRY_ALERTS = %w[ expired expiring_soon ].freeze

    # 品目 1 件の現在値。status は Symbol で渡しても文字列にそろえる
    Entry = Data.define(:item_id, :name, :purchase_status, :expiry_status, :snoozed) do
      def initialize(item_id:, name:, purchase_status:, expiry_status:, snoozed: false)
        super(item_id: item_id, name: name, purchase_status: purchase_status.to_s,
              expiry_status: expiry_status.to_s, snoozed: !!snoozed)
      end
    end

    # 前回突き合わせたときの値。列が nil (行が無い / 初回) なら unknown / fresh とみなす
    Previous = Data.define(:purchase_status, :expiry_status) do
      def initialize(purchase_status: nil, expiry_status: nil)
        purchase = purchase_status.to_s
        expiry = expiry_status.to_s

        super(purchase_status: purchase.empty? ? UNKNOWN_PURCHASE : purchase,
              expiry_status: expiry.empty? ? FRESH_EXPIRY : expiry)
      end
    end

    # 悪化した品目。種別ごとに分けて持つ (ユーザーごとの ON/OFF で片方だけを残せるように)
    Summary = Data.define(:purchase_items, :expiry_items) do
      def empty?
        purchase_items.empty? && expiry_items.empty?
      end

      def any?
        !empty?
      end

      # 通知種別 (notify_purchases / notify_expiries) で絞る。
      # その人にとって 0 件になったら送らない (呼び出し側が empty? を見る)
      def only(purchases:, expiries:)
        Summary.new(purchase_items: purchases ? purchase_items : [],
                    expiry_items: expiries ? expiry_items : [])
      end

      # 通知に出す品目名 (購入 → 期限の順。両方で悪化した品目は 1 度だけ)
      def names
        (purchase_items + expiry_items).map(&:name).uniq
      end

      # 「購入推奨 1 件・そろそろ購入 2 件・期限切れ 1 件・期限間近 1 件 — トイレットペーパー ほか」。
      #
      # **ステータスごとに数える** (soon をまとめて「購入推奨」と言うと、そこまで急いでいない
      # 品目まで買いに行かせてしまう)。0 件の内訳は並べない。
      # 語彙は画面と同じものを使うので、ラベルは呼び出し側が I18n から渡す
      # (この PORO は Rails に依存しない)。
      # purchase_labels / expiry_labels: { "urgent" => "購入推奨", ... }
      def body(purchase_labels:, expiry_labels:)
        counts = breakdown(purchase_items, PURCHASE_ALERTS, purchase_labels, :purchase_status) +
          breakdown(expiry_items, EXPIRY_ALERTS, expiry_labels, :expiry_status)

        [ counts.join("・"), lead ].reject { |part| part.nil? || part.empty? }.join(" — ")
      end

      private
        def breakdown(items, statuses, labels, attribute)
          statuses.filter_map do |status|
            count = items.count { _1.public_send(attribute) == status }
            "#{labels.fetch(status)} #{count} 件" if count.positive?
          end
        end

        def lead
          shown = names
          return nil if shown.empty?

          shown.size == 1 ? shown.first : "#{shown.first} ほか"
        end
    end

    # item_alert_states に書き戻す値 (次の朝に「前回値」として比べられる)
    State = Data.define(:item_id, :purchase_status, :expiry_status)

    NOTHING = Summary.new(purchase_items: [], expiry_items: [])

    module_function

    # entries: Entry の配列 / previous: { item_id => Previous }
    def call(entries:, previous: {})
      entries = Array(entries)

      Summary.new(
        purchase_items: entries.select { purchase_worsened?(_1, previous_for(previous, _1)) },
        expiry_items: entries.select { expiry_worsened?(_1, previous_for(previous, _1)) }
      )
    end

    def previous_for(previous, entry)
      previous[entry.item_id] || Previous.new
    end

    # 次の朝に「前回値」として比べる値。全品目ぶんを返す (改善も記録する)
    def states(entries:, previous: {})
      Array(entries).map { state_for(_1, previous_for(previous, _1)) }
    end

    # **見送り中の品目の要購入ステータスは前回値のまま据え置く。**
    # 現在値で記録すると、見送り中に ok -> urgent と悪化した品目が、見送りが切れたあとも
    # 「横ばい」になって二度と通知されない。期限は見送りの対象外なので現在値で記録する
    def state_for(entry, previous)
      State.new(
        item_id: entry.item_id,
        purchase_status: entry.snoozed ? previous.purchase_status : entry.purchase_status,
        expiry_status: entry.expiry_status
      )
    end

    def purchase_worsened?(entry, previous)
      # 「今回は買わない」と見送った品目では鳴らさない
      # (docs/spec/02-forecast.md 14 節の申し送り。買い物リストの境界と同じ扱い)
      return false if entry.snoozed
      return false unless PURCHASE_ALERTS.include?(entry.purchase_status)

      worse?(PURCHASE_RANK, entry.purchase_status, previous.purchase_status)
    end

    def expiry_worsened?(entry, previous)
      return false unless EXPIRY_ALERTS.include?(entry.expiry_status)

      worse?(EXPIRY_RANK, entry.expiry_status, previous.expiry_status)
    end

    # 知らない値 (列に古い値が残っている等) は「いちばん良い状態」とみなして比べる。
    # ここで例外にすると、1 品目の値がおかしいだけで毎朝のダイジェストが丸ごと止まる
    def worse?(rank, current, before)
      current_rank = rank[current]
      return false if current_rank.nil?

      current_rank > (rank[before] || rank.values.min)
    end
  end
end
