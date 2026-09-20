require_relative "shopping_list_helper"

# 買い物リストの組み立て (docs/spec/01-domain-model.md 判断 5)。
# DB に触らないので rails_helper を読まず、spec_helper だけで実行できる。
RSpec.describe ShoppingLists::Merger do
  include ShoppingListSpecHelper

  def names(rows)
    rows.map(&:name)
  end

  describe "導出 (要購入判定) からの行" do
    it "status が urgent の品目は自動で並ぶ" do
      list = merge(items: [ item(id: 1, name: "トイレットペーパー") ],
        forecasts: { 1 => forecast(status: :urgent) })

      expect(names(list.rows)).to eq [ "トイレットペーパー" ]
      expect(only_row(list)).to be_auto
      expect(only_row(list).status).to eq :urgent
    end

    it "status が soon の品目も並ぶ" do
      list = merge(items: [ item(id: 1, name: "せんざい") ],
        forecasts: { 1 => forecast(status: :soon) })

      expect(names(list.rows)).to eq [ "せんざい" ]
    end

    it "ok と unknown は並ばない" do
      list = merge(
        items: [ item(id: 1, name: "ok のしな"), item(id: 2, name: "unknown のしな") ],
        forecasts: { 1 => forecast(status: :ok), 2 => forecast(status: :unknown) }
      )

      expect(list.rows).to be_empty
    end

    it "判定の無い品目 (アーカイブ済みで BatchForecaster の結果に入らない) は並ばない" do
      list = merge(items: [ item(id: 1, name: "アーカイブ済み") ], forecasts: {})

      expect(list.rows).to be_empty
    end

    it "永続行が無くても並ぶ (GET では行を作らない)" do
      list = merge(items: [ item(id: 1) ], forecasts: { 1 => forecast(status: :urgent) })

      expect(only_row(list).record).to be_nil
      expect(only_row(list).record_id).to be_nil
    end
  end

  describe "永続行とのマージ" do
    it "チェック済みの永続行はチェック済みとして出る" do
      list = merge(items: [ item(id: 1) ], forecasts: { 1 => forecast(status: :urgent) },
        records: [ record(item_id: 1, checked_at: Time.now) ])

      expect(only_row(list)).to be_checked
      expect(list.checked_rows.size).to eq 1
    end

    it "自動の条件を外れた品目 (購入して ok に戻った) の永続行は、チェック済みなら残る" do
      list = merge(items: [ item(id: 1, name: "かった") ], forecasts: { 1 => forecast(status: :ok) },
        records: [ record(item_id: 1, checked_at: Time.now) ])

      expect(names(list.rows)).to eq [ "かった" ]
      expect(only_row(list)).not_to be_auto
    end

    it "自動の条件を外れた品目の永続行は、チェック済みでなければ出さない" do
      list = merge(items: [ item(id: 1) ], forecasts: { 1 => forecast(status: :ok) },
        records: [ record(item_id: 1, quantity: 3) ])

      expect(list.rows).to be_empty
    end

    it "手動で追加した品目は、判定が ok でも並ぶ" do
      list = merge(items: [ item(id: 1, name: "てどうついか") ], forecasts: { 1 => forecast(status: :ok) },
        records: [ record(item_id: 1, added_manually: true) ])

      expect(names(list.rows)).to eq [ "てどうついか" ]
      expect(only_row(list).kind).to eq :manual
    end

    it "手動追加した自由入力の行が並ぶ" do
      list = merge(records: [ record(free_text: "でんち (たんさん)", added_manually: true) ])

      expect(names(list.rows)).to eq [ "でんち (たんさん)" ]
      expect(only_row(list)).to be_free_text
      expect(only_row(list).item).to be_nil
    end

    it "アーカイブ済みの品目は永続行があっても並ばない (items に渡されない)" do
      list = merge(items: [], forecasts: {},
        records: [ record(item_id: 1, checked_at: Time.now, added_manually: true) ])

      expect(list.rows).to be_empty
    end
  end

  describe "スヌーズ" do
    it "スヌーズ中の品目は自動セクションに出さず、スヌーズ中として数える" do
      list = merge(items: [ item(id: 1, name: "すぬーず") ], forecasts: { 1 => forecast(status: :urgent) },
        records: [ record(item_id: 1, snoozed_until: today + 3) ])

      expect(list.rows).to be_empty
      expect(names(list.snoozed_rows)).to eq [ "すぬーず" ]
      expect(list.snoozed_count).to eq 1
    end

    it "snoozed_until が today と同じ日はまだスヌーズ中" do
      list = merge(items: [ item(id: 1) ], forecasts: { 1 => forecast(status: :urgent) },
        records: [ record(item_id: 1, snoozed_until: today) ])

      expect(list.rows).to be_empty
      expect(list.snoozed_rows.size).to eq 1
    end

    it "snoozed_until が前日なら自動で戻る (期限切れのスヌーズは無視する)" do
      list = merge(items: [ item(id: 1) ], forecasts: { 1 => forecast(status: :urgent) },
        records: [ record(item_id: 1, snoozed_until: today - 1) ])

      expect(list.rows.size).to eq 1
      expect(list.snoozed_rows).to be_empty
    end

    it "チェック済みならスヌーズ中でも一覧に出す (買うと決めたほうを優先する)" do
      list = merge(items: [ item(id: 1) ], forecasts: { 1 => forecast(status: :urgent) },
        records: [ record(item_id: 1, checked_at: Time.now, snoozed_until: today + 3) ])

      expect(list.rows.size).to eq 1
      expect(list.snoozed_rows).to be_empty
    end

    it "スヌーズ中でも判定が ok に戻って手動でもなければ、スヌーズ一覧にも出さない" do
      list = merge(items: [ item(id: 1) ], forecasts: { 1 => forecast(status: :ok) },
        records: [ record(item_id: 1, snoozed_until: today + 3) ])

      expect(list.rows).to be_empty
      expect(list.snoozed_rows).to be_empty
    end
  end

  describe "並び順" do
    it "urgent → soon → 手動 (品目) → 自由入力の順に並ぶ" do
      list = merge(
        items: [ item(id: 1, name: "soon"), item(id: 2, name: "urgent"), item(id: 3, name: "manual") ],
        forecasts: {
          1 => forecast(status: :soon), 2 => forecast(status: :urgent), 3 => forecast(status: :ok)
        },
        records: [ record(item_id: 3, added_manually: true), record(free_text: "じゆう", added_manually: true) ]
      )

      expect(names(list.rows)).to eq [ "urgent", "soon", "manual", "じゆう" ]
    end

    it "同じ status の中は days_left の小さい順で、nil は最後" do
      list = merge(
        items: [ item(id: 1, name: "5 日"), item(id: 2, name: "ペース不明"), item(id: 3, name: "1 日") ],
        forecasts: {
          1 => forecast(status: :urgent, days_left: 5),
          2 => forecast(status: :urgent, days_left: nil),
          3 => forecast(status: :urgent, days_left: 1)
        }
      )

      expect(names(list.rows)).to eq [ "1 日", "5 日", "ペース不明" ]
    end

    it "days_left が同じならよみ順で並ぶ (よみが無ければ名前)" do
      list = merge(
        items: [
          item(id: 1, name: "洗剤", name_reading: "せんざい"),
          item(id: 2, name: "あぶら"),
          item(id: 3, name: "米", name_reading: "こめ")
        ],
        forecasts: {
          1 => forecast(status: :urgent, days_left: 2),
          2 => forecast(status: :urgent, days_left: 2),
          3 => forecast(status: :urgent, days_left: 2)
        }
      )

      expect(names(list.rows)).to eq [ "あぶら", "米", "洗剤" ]
    end

    it "自由入力どうしは文字の順に並ぶ" do
      list = merge(records: [
        record(free_text: "ぱん", added_manually: true).tap { _1.id = 2 },
        record(free_text: "あめ", added_manually: true).tap { _1.id = 1 }
      ])

      expect(names(list.rows)).to eq [ "あめ", "ぱん" ]
    end

    it "スヌーズ一覧も同じ規則で並ぶ" do
      list = merge(
        items: [ item(id: 1, name: "あと 9 日"), item(id: 2, name: "あと 1 日") ],
        forecasts: {
          1 => forecast(status: :urgent, days_left: 9), 2 => forecast(status: :urgent, days_left: 1)
        },
        records: [
          record(item_id: 1, snoozed_until: today + 1), record(item_id: 2, snoozed_until: today + 1)
        ]
      )

      expect(names(list.snoozed_rows)).to eq [ "あと 1 日", "あと 9 日" ]
    end
  end

  describe "在庫と希望数量" do
    it "在庫は Forecast::Result#quantity (期限切れを除いた q) を使う" do
      list = merge(items: [ item(id: 1) ], forecasts: { 1 => forecast(status: :urgent, quantity: 2) })

      expect(only_row(list).stock_quantity).to eq 2
    end

    it "最低在庫数が無く入数の既定値があれば 1 パック分を推奨する" do
      list = merge(items: [ item(id: 1, default_pack_size: 12) ],
        forecasts: { 1 => forecast(status: :urgent, quantity: 0) })

      expect(only_row(list).recommended_quantity).to eq 12
      expect(only_row(list).quantity).to eq 12
    end

    it "入数が無く最低在庫数があれば、最低在庫数を 1 つ上回るまでの数を推奨する" do
      list = merge(items: [ item(id: 1, minimum_quantity: 3) ],
        forecasts: { 1 => forecast(status: :urgent, quantity: 1) })

      expect(only_row(list).recommended_quantity).to eq 3
    end

    # 1 パックでは最低在庫数に届かないことがある (最低 10・在庫 0・入数 4 なら 3 パック要る)
    it "最低在庫数と入数の両方があれば、不足分を入数の倍数に切り上げる" do
      list = merge(items: [ item(id: 1, minimum_quantity: 10, default_pack_size: 4) ],
        forecasts: { 1 => forecast(status: :urgent, quantity: 0) })

      expect(only_row(list).recommended_quantity).to eq 12
    end

    it "不足分が 1 パックで足りるときは 1 パック" do
      list = merge(items: [ item(id: 1, minimum_quantity: 3, default_pack_size: 4) ],
        forecasts: { 1 => forecast(status: :urgent, quantity: 1) })

      expect(only_row(list).recommended_quantity).to eq 4
    end

    it "最低在庫数を満たしていても推奨は 1 以上になる" do
      list = merge(items: [ item(id: 1, minimum_quantity: 3) ],
        forecasts: { 1 => forecast(status: :soon, quantity: 3) })

      expect(only_row(list).recommended_quantity).to eq 1
    end

    it "推奨数量は品目の数量の上限を超えない" do
      list = merge(items: [ item(id: 1, minimum_quantity: ShoppingLists::Row::MAX_QUANTITY) ],
        forecasts: { 1 => forecast(status: :urgent, quantity: 0) })

      expect(only_row(list).recommended_quantity).to eq ShoppingLists::Row::MAX_QUANTITY
    end

    it "入数も最低在庫数も無ければ 1 を推奨する" do
      list = merge(items: [ item(id: 1) ], forecasts: { 1 => forecast(status: :urgent) })

      expect(only_row(list).recommended_quantity).to eq 1
    end

    it "数量の上書きがあれば推奨より優先される" do
      list = merge(items: [ item(id: 1, default_pack_size: 12) ],
        forecasts: { 1 => forecast(status: :urgent) },
        records: [ record(item_id: 1, quantity: 2) ])

      expect(only_row(list).quantity).to eq 2
      expect(only_row(list).recommended_quantity).to eq 12
      expect(only_row(list)).to be_quantity_overridden
    end

    it "行の DOM id は永続行の有無で変わらない (品目の行は品目 id で決める)" do
      without_record = merge(items: [ item(id: 7) ], forecasts: { 7 => forecast(status: :urgent) })
      with_record = merge(items: [ item(id: 7) ], forecasts: { 7 => forecast(status: :urgent) },
        records: [ record(item_id: 7, checked_at: Time.now) ])

      expect(only_row(without_record).dom_id).to eq "shopping_list_row_item_7"
      expect(only_row(with_record).dom_id).to eq "shopping_list_row_item_7"
    end

    it "自由入力の行の DOM id は永続行の id で決まる" do
      list = merge(records: [ record(free_text: "でんち", added_manually: true).tap { _1.id = 42 } ])

      expect(only_row(list).dom_id).to eq "shopping_list_row_entry_42"
    end

    it "自由入力の行は在庫を持たず、希望数量の既定は 1" do
      list = merge(records: [ record(free_text: "でんち", added_manually: true) ])

      expect(only_row(list).stock_quantity).to be_nil
      expect(only_row(list).quantity).to eq 1
    end
  end

  describe "一覧の区分" do
    it "自動の行と手動の行を分けて取り出せる" do
      list = merge(
        items: [ item(id: 1, name: "じどう"), item(id: 2, name: "てどう") ],
        forecasts: { 1 => forecast(status: :urgent), 2 => forecast(status: :ok) },
        records: [ record(item_id: 2, added_manually: true), record(free_text: "じゆう", added_manually: true) ]
      )

      expect(names(list.auto_rows)).to eq [ "じどう" ]
      expect(names(list.manual_rows)).to eq [ "てどう", "じゆう" ]
    end

    it "チェック済みは品目つきと自由入力に分けて取り出せる (まとめ購入に使う)" do
      list = merge(
        items: [ item(id: 1, name: "ひんもく") ],
        forecasts: { 1 => forecast(status: :urgent) },
        records: [
          record(item_id: 1, checked_at: Time.now),
          record(free_text: "じゆう", checked_at: Time.now, added_manually: true)
        ]
      )

      expect(names(list.checked_item_rows)).to eq [ "ひんもく" ]
      expect(names(list.checked_free_text_rows)).to eq [ "じゆう" ]
      expect(list.checked_count).to eq 2
    end
  end
end
