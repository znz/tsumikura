require "rails_helper"

RSpec.describe Stock::ReviseLot, type: :model do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:item) { create(:item) }
  let(:user) { create(:user) }
  let(:lot) { create(:lot, item: item, user: user, initial_quantity: 12) }

  describe "数量の編集" do
    it "数量を減らすと在庫が再計算される" do
      described_class.call(lot, initial_quantity: 6)

      expect(lot.reload.remaining_quantity).to eq 6
      expect(item.reload.current_quantity).to eq 6
    end

    it "数量を増やしても在庫が再計算される" do
      described_class.call(lot, initial_quantity: 20)

      expect(item.reload.current_quantity).to eq 20
    end

    it "入庫の movement の数量も直る (台帳が正)" do
      described_class.call(lot, initial_quantity: 6)

      expect(lot.stock_movements.sole.quantity).to eq 6
    end

    it "入数 × パック数でも編集できる" do
      described_class.call(lot, pack_size: 6, pack_count: 3)

      expect(lot.reload.initial_quantity).to eq 18
      expect(item.reload.current_quantity).to eq 18
    end

    it "一部を使ったあとに残りちょうどまで減らすと残数 0 になり depleted_at が打たれる" do
      create(:stock_movement, lot: lot, kind: :usage, quantity: -5)
      Stock::Recalculator.call(item)

      described_class.call(lot, initial_quantity: 5)

      expect(lot.reload.remaining_quantity).to eq 0
      expect(lot.depleted_at).to be_present
      expect(item.reload.current_quantity).to eq 0
    end

    it "既に使われた数より小さくは編集できず、在庫も台帳も変わらない" do
      create(:stock_movement, lot: lot, kind: :usage, quantity: -5)
      Stock::Recalculator.call(item)

      result = described_class.call(lot, initial_quantity: 4)

      expect(result.errors[:initial_quantity]).to be_present
      expect(lot.reload.initial_quantity).to eq 12
      expect(lot.stock_movements.kind_purchase.sole.quantity).to eq 12
      expect(item.reload.current_quantity).to eq 7
    end
  end

  describe "購入日の編集" do
    it "movement の occurred_on も直り、tracking_started_on が追随する" do
      described_class.call(lot, acquired_on: Date.current - 30)

      expect(lot.stock_movements.sole.occurred_on).to eq Date.current - 30
      expect(item.reload.tracking_started_on).to eq Date.current - 30
    end

    it "未来の日付には編集できない" do
      travel_to Time.current.change(hour: 0, min: 10) do
        result = described_class.call(lot, acquired_on: Date.current + 1)

        expect(result.errors[:acquired_on]).to be_present
      end

      # travel_to のブロックを抜けると、外側の freeze_time で固定した時刻に戻る
      expect(lot.reload.acquired_on).to eq Date.current
    end
  end

  describe "その他の項目" do
    it "店舗・金額・期限・メモを編集できる" do
      store = create(:store)

      described_class.call(lot, store_id: store.id, price_yen: 456,
        expires_on: Date.current + 30, note: "特売")

      lot.reload
      expect(lot.store).to eq store
      expect(lot.price_yen).to eq 456
      expect(lot.expires_on).to eq Date.current + 30
      expect(lot.note).to eq "特売"
    end

    it "店舗を外せる" do
      lot.update_column(:store_id, create(:store).id)

      described_class.call(lot, store_id: "")

      expect(lot.reload.store_id).to be_nil
    end
  end

  # 古い画面から保存されると、ロック前に読んだ数量で入庫 movement を書き換えてしまう
  describe "ロックの前に読んだロット" do
    it "別の画面で先に数量が変わっていても、ロットと入庫の記録がずれない" do
      stale = Lot.find(lot.id)
      described_class.call(Lot.find(lot.id), initial_quantity: 24)

      described_class.call(stale, note: "メモだけ変える")

      stale.reload
      expect(stale.initial_quantity).to eq 24
      expect(stale.note).to eq "メモだけ変える"
      expect(stale.stock_movements.sole.quantity).to eq 24
      expect(item.reload.current_quantity).to eq 24
    end
  end

  # 入庫の記録が無いロットは台帳が壊れている。黙って直さず気づけるようにする
  it "入庫の記録が無いロットは例外になり、編集も保存されない" do
    lot.stock_movements.destroy_all

    expect {
      described_class.call(lot, note: "メモ")
    }.to raise_error(Stock::ReviseLot::InboundMovementMissing)

    expect(lot.reload.note).to be_nil
  end

  it "最初の書き込みより前に品目を行ロックする" do
    lot
    statements = recorded_sql { described_class.call(lot, note: "メモ") }

    expect(first_lock_index(statements)).not_to be_nil
    expect(first_lock_index(statements)).to be < first_write_index(statements)
  end

  describe "編集できない項目" do
    it "キャッシュ列は渡しても無視される" do
      described_class.call(lot, remaining_quantity: 999, depleted_at: Time.current)

      expect(lot.reload.remaining_quantity).to eq 12
      expect(lot.depleted_at).to be_nil
    end

    it "由来 (購入 / 初期在庫 / 調整) は渡しても変わらない" do
      described_class.call(lot, kind: "adjustment")

      expect(lot.reload).to be_kind_purchase
    end

    it "記録者は渡しても変わらない" do
      described_class.call(lot, user_id: create(:user).id)

      expect(lot.reload.user_id).to eq user.id
    end

    it "品目は渡しても変わらない (別の品目に付け替えられない)" do
      other = create(:item)

      described_class.call(lot, item_id: other.id)

      expect(lot.reload.item_id).to eq item.id
      expect(other.reload.current_quantity).to eq 0
    end
  end

  # 途中で例外が起きたときに movement だけが直ると在庫が狂う
  it "再計算が失敗したら数量も movement も編集前のまま" do
    lot
    allow(Stock::Recalculator).to receive(:call).and_raise("boom")

    expect { described_class.call(lot, initial_quantity: 6) }.to raise_error("boom")

    expect(lot.reload.initial_quantity).to eq 12
    expect(lot.stock_movements.sole.quantity).to eq 12
  end

  # 棚卸でロット別に数えると、そのロットに正の adjustment が足される。
  # 入庫の movement (購入の 1 行) と取り違えると、棚卸の記録を書き換えてしまう
  describe "棚卸のプラス差分が付いたロット" do
    let!(:lot) { create(:lot, item: item, initial_quantity: 3, acquired_on: Date.current - 3) }

    before do
      stock_take = create(:stock_take, user: user, counted_on: Date.current)
      create(:stock_take_entry, stock_take: stock_take, item: item, lot: lot,
        expected_quantity: 3, counted_quantity: 5)
      Stock::FinalizeStockTake.call(stock_take, user: user)
    end

    it "数量を編集しても、直るのは入庫の movement だけで棚卸の +2 は残る" do
      described_class.call(lot, initial_quantity: 4)

      lot.reload
      expect(lot.initial_quantity).to eq 4
      expect(lot.remaining_quantity).to eq 6
      expect(lot.stock_movements.kind_purchase.sole.quantity).to eq 4
      expect(lot.stock_movements.kind_adjustment.sole.quantity).to eq 2
    end

    # 出庫が無ければ、数量を減らしても残数は負にならない
    # (購入 3 + 棚卸 +2。数量 1 にしても 1 + 2 = 3 残る)
    it "出庫が無ければ数量を減らせる" do
      expect(described_class.call(lot, initial_quantity: 1).errors).to be_empty
      expect(lot.reload.remaining_quantity).to eq 3
    end

    # 境界: 購入 3 + 棚卸 +2 − 使用 4 = 残 1。
    # 直すのは入庫の movement だけなので「Σ movements − 旧入庫 (3) + 新数量 >= 0」、
    # つまり新数量 >= 2 なら許され、1 なら残が −1 になるので拒否される
    describe "使用が紐づいたあと (購入 3 + 棚卸 +2 − 使用 4)" do
      before do
        Stock::RecordUsage.call(item: item, user: user,
          attributes: { quantity: 4, used_on: Date.current, lot_id: lot.id })
      end

      it "残数が負になる編集 (数量 1) は検証エラーになる" do
        revised = described_class.call(lot, initial_quantity: 1)

        expect(revised.errors[:initial_quantity]).to be_present
        expect(lot.reload.initial_quantity).to eq 3
        expect(lot.remaining_quantity).to eq 1
      end

      it "棚卸で足された分だけ小さい数量 (2) には編集できる" do
        expect(described_class.call(lot, initial_quantity: 2).errors).to be_empty
        expect(lot.reload.remaining_quantity).to eq 0
      end
    end
  end
end
