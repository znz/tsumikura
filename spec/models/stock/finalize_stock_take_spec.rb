require "rails_helper"

RSpec.describe Stock::FinalizeStockTake, type: :model do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:user) { create(:user) }
  let(:item) { create(:item, name: "トイレットペーパー", unit: "ロール") }
  let(:stock_take) { create(:stock_take, user: user, counted_on: Date.current) }

  def add_entry(counted:, target: item, lot: nil, expected: nil)
    create(:stock_take_entry, stock_take: stock_take, item: target, lot: lot,
      expected_quantity: expected || (lot ? lot.remaining_quantity : target.current_quantity),
      counted_quantity: counted)
  end

  def finalize(target = stock_take)
    described_class.call(target, user: user)
  end

  # 下書きは在庫にいっさい影響しない (docs/spec/01-domain-model.md 判断 3)
  describe "下書き" do
    it "明細を作っただけでは在庫も台帳も動かない" do
      create(:lot, item: item, initial_quantity: 10)

      expect { add_entry(counted: 7) }.not_to change { StockMovement.count }
      expect(item.reload.current_quantity).to eq 10
    end
  end

  describe "マイナス差分" do
    before { create(:lot, item: item, initial_quantity: 10) }

    it "記録在庫 10・実数 7 なら difference は -3" do
      entry = add_entry(counted: 7)

      finalize

      expect(entry.reload.difference).to eq(-3)
      expect(entry.expected_quantity).to eq 10
    end

    it "在庫が実数に一致する" do
      add_entry(counted: 7)

      finalize

      expect(item.reload.current_quantity).to eq 7
    end

    it "負の調整 (kind: adjustment) の movement が作られ、明細に紐づく" do
      entry = add_entry(counted: 7)

      expect { finalize }.to change { StockMovement.count }.by(1)

      movement = entry.reload.stock_movements.sole
      expect(movement).to be_kind_adjustment
      expect(movement.quantity).to eq(-3)
      expect(movement.occurred_on).to eq stock_take.counted_on
      expect(movement.usage_record).to be_nil
      expect(movement.user).to eq user
    end

    it "期限の近いロットから引かれる (期限切れは最後)" do
      item.lots.destroy_all
      Stock::Recalculator.call(item)
      expired = create(:lot, item: item, initial_quantity: 2, expires_on: Date.current - 1)
      near = create(:lot, item: item, initial_quantity: 2, expires_on: Date.current + 1)
      far = create(:lot, item: item, initial_quantity: 2, expires_on: Date.current + 30)
      add_entry(counted: 3)

      finalize

      expect(near.reload.remaining_quantity).to eq 0
      expect(far.reload.remaining_quantity).to eq 1
      expect(expired.reload.remaining_quantity).to eq 2
    end

    it "複数のロットに分かれると movement も分かれる" do
      item.lots.destroy_all
      Stock::Recalculator.call(item)
      create(:lot, item: item, initial_quantity: 2, expires_on: Date.current + 1)
      create(:lot, item: item, initial_quantity: 2, expires_on: Date.current + 30)
      entry = add_entry(counted: 1)

      finalize

      expect(entry.reload.stock_movements.sum(:quantity)).to eq(-3)
      expect(entry.stock_movements.count).to eq 2
    end

    # 棚卸のマイナス差分は消費に数える (docs/spec/02-forecast.md 3 節)
    it "item.last_consumed_on が棚卸日になる" do
      add_entry(counted: 7)
      stock_take.update!(counted_on: Date.current - 2)

      finalize

      expect(item.reload.last_consumed_on).to eq Date.current - 2
    end

    it "不足しても補填の調整ロットは作らない (在庫を超える差分は台帳の異常)" do
      entry = add_entry(counted: 0)
      # 確定を待つ間に別の画面で使い切られ、キャッシュだけが残った状態を作る
      item.update_column(:current_quantity, 99)
      entry.update_columns(expected_quantity: 99, difference: -99)

      expect { finalize }.to raise_error(described_class::LedgerInconsistent)
      expect(Lot.kind_adjustment.count).to eq 0
    end
  end

  describe "プラス差分" do
    before { create(:lot, item: item, initial_quantity: 10) }

    it "記録在庫 10・実数 12 なら kind: adjustment のロットが 1 件 (数量 2・期限 nil) 作られる" do
      add_entry(counted: 12)

      expect { finalize }.to change { Lot.count }.by(1)

      lot = Lot.kind_adjustment.sole
      expect(lot.initial_quantity).to eq 2
      expect(lot.expires_on).to be_nil
      expect(lot.price_yen).to be_nil
      expect(lot.acquired_on).to eq stock_take.counted_on
      expect(item.reload.current_quantity).to eq 12
    end

    # 持たせないと Stock::UsageMovements#discard! が「空の調整ロット」として消してしまう
    it "調整ロットには使用記録に紐づかない入庫 movement が必ず付く" do
      entry = add_entry(counted: 12)

      finalize

      movement = entry.reload.stock_movements.sole
      expect(movement).to be_kind_adjustment
      expect(movement.quantity).to eq 2
      expect(movement.usage_record).to be_nil
      expect(movement.lot).to be_kind_adjustment
    end

    # 合計で数えたときは、どのロットの分なのか分からない。既存のロットに足すと
    # 「知らない期限」を勝手に主張することになる (ロット別に数えたときは別扱い)
    it "合計で数えた明細では、既存のロットに正の調整を足さない" do
      existing = create(:lot, item: item, initial_quantity: 5)
      add_entry(counted: 20)

      finalize

      expect(existing.reload.stock_movements.where(quantity: 1..).count).to eq 1
      expect(existing.stock_movements.sole).to be_kind_purchase
    end

    # プラス差分は「使った」ではないので予測のアンカーを動かさない
    it "item.last_consumed_on は動かない" do
      add_entry(counted: 12)

      finalize

      expect(item.reload.last_consumed_on).to be_nil
    end
  end

  describe "差分 0 と未入力" do
    before { create(:lot, item: item, initial_quantity: 10) }

    it "差分 0 の明細は StockMovement を作らない" do
      add_entry(counted: 10)

      expect { finalize }.not_to change { StockMovement.count }
      expect(item.reload.current_quantity).to eq 10
    end

    it "実数未入力 (counted_quantity が nil) の明細はスキップされる" do
      entry = add_entry(counted: nil)
      # 1 件も数えていない棚卸は確定できないので、別の品目を 1 件だけ数えておく
      other = create(:item)
      create(:lot, item: other, initial_quantity: 2)
      add_entry(counted: 2, target: other)

      expect { finalize }.not_to change { StockMovement.count }
      expect(entry.reload.difference).to be_nil
      expect(item.reload.current_quantity).to eq 10
    end
  end

  describe "確定時点の記録在庫を取り直す" do
    before { create(:lot, item: item, initial_quantity: 10) }

    it "下書きを作ったあとに在庫が変わっていたら、その値で差分を出し直す" do
      entry = add_entry(counted: 7, expected: 10)
      # 下書き中に 4 使われた (記録在庫は 6 になる)
      Stock::RecordUsage.call(item: item, user: user, attributes: { quantity: 4, used_on: Date.current })

      finalize

      expect(entry.reload.expected_quantity).to eq 6
      expect(entry.difference).to eq 1
      expect(item.reload.current_quantity).to eq 7
    end

    it "取り直した結果が差分 0 になれば movement を作らない" do
      add_entry(counted: 6, expected: 10)
      Stock::RecordUsage.call(item: item, user: user, attributes: { quantity: 4, used_on: Date.current })

      expect { finalize }.not_to change { StockMovement.count }
    end
  end

  describe "ロット別に数えた明細" do
    let(:item) { create(:item, :tracks_expiry, name: "たまご", unit: "個") }
    let!(:near) { create(:lot, item: item, initial_quantity: 6, expires_on: Date.current + 1) }
    let!(:far) { create(:lot, item: item, initial_quantity: 6, expires_on: Date.current + 30) }

    it "そのロットに対する差分として処理する (ほかのロットからは引かない)" do
      add_entry(counted: 4, lot: far)

      finalize

      expect(far.reload.remaining_quantity).to eq 4
      expect(near.reload.remaining_quantity).to eq 6
      expect(item.reload.current_quantity).to eq 10
    end

    # 新しい調整ロットを作ると、次の棚卸で同じ実物が 2 行に見えて数えるたびに
    # 水増しされる (ユーザーがロットを特定しているので期限を主張することにもならない)
    it "ロット別のプラス差分は、そのロットに正の調整を足す (新しいロットは作らない)" do
      entry = add_entry(counted: 8, lot: far)

      expect { finalize }.not_to change { Lot.count }

      expect(far.reload.remaining_quantity).to eq 8
      expect(item.reload.current_quantity).to eq 14
      movement = entry.reload.stock_movements.sole
      expect(movement.lot).to eq far
      expect(movement.quantity).to eq 2
      expect(movement).to be_kind_adjustment
    end

    it "使い切ったロットをロット別に数え直すと、depleted_at が消えて残数が戻る" do
      Stock::RecordUsage.call(item: item, user: user,
        attributes: { quantity: 6, used_on: Date.current, lot_id: far.id })
      expect(far.reload.depleted_at).to be_present

      add_entry(counted: 2, lot: far)
      finalize

      expect(far.reload.remaining_quantity).to eq 2
      expect(far.depleted_at).to be_nil
    end

    # 同じロットをもう一度数えても、差分 0 に収束する (水増しを繰り返さない)
    it "もう一度同じ実数で数えると差分 0 になる" do
      add_entry(counted: 8, lot: far)
      finalize

      second = create(:stock_take, user: user, counted_on: Date.current)
      entry = create(:stock_take_entry, stock_take: second, item: item, lot: far,
        expected_quantity: far.reload.remaining_quantity, counted_quantity: 8)

      expect { described_class.call(second, user: user) }.not_to change { StockMovement.count }
      expect(entry.reload.difference).to eq 0
    end

    it "同じ品目の複数のロットを別々に数えられる" do
      add_entry(counted: 4, lot: near)
      add_entry(counted: 5, lot: far)

      finalize

      expect(near.reload.remaining_quantity).to eq 4
      expect(far.reload.remaining_quantity).to eq 5
      expect(item.reload.current_quantity).to eq 9
    end

    it "確定時点のロットの残数を取り直す" do
      entry = add_entry(counted: 4, lot: far, expected: 6)
      Stock::RecordUsage.call(item: item, user: user,
        attributes: { quantity: 2, used_on: Date.current, lot_id: far.id })

      finalize

      expect(entry.reload.expected_quantity).to eq 4
      expect(entry.difference).to eq 0
    end
  end

  describe "複数の品目" do
    let(:other) { create(:item, name: "ラップ") }

    before do
      create(:lot, item: item, initial_quantity: 10)
      create(:lot, item: other, initial_quantity: 4)
    end

    it "品目ごとに差分が反映される" do
      add_entry(counted: 7)
      add_entry(counted: 6, target: other)

      finalize

      expect(item.reload.current_quantity).to eq 7
      expect(other.reload.current_quantity).to eq 6
    end

    # 複数の品目をロックするときは id の昇順 (docs/spec/01-domain-model.md 5 節)
    it "品目を id の昇順でロックする" do
      first, second = [ item, other ].sort_by(&:id)
      add_entry(counted: 1, target: second)
      add_entry(counted: 1, target: first)
      # let は遅延評価なので、記録を始める前にすべて作っておく
      stock_take.stock_take_entries.load

      ids = recorded_lock_ids("items") { finalize }

      expect(ids.uniq).to eq [ first.id, second.id ]
    end
  end

  describe "確定" do
    before { create(:lot, item: item, initial_quantity: 10) }

    it "finalized_at が入る" do
      add_entry(counted: 7)

      expect { finalize }.to change { stock_take.reload.finalized_at }.from(nil)
      expect(stock_take).to be_finalized
    end

    # 2 台で同時に確定ボタンを押されることがある。判定はロックの「あと」でなければ
    # 意味がないので、**確定前に読んだ古いインスタンス**で確かめる
    it "確定済みの棚卸をもう一度確定しようとすると AlreadyFinalized になり、在庫も動かない" do
      add_entry(counted: 7)
      stale = stock_take
      finalize(StockTake.find(stock_take.id))

      expect {
        expect { finalize(stale) }.to raise_error(described_class::AlreadyFinalized)
      }.not_to change { StockMovement.count }

      expect(item.reload.current_quantity).to eq 7
    end

    # 在庫は動かないのに棚卸日だけが進み、以降の記録すべてに
    # 「直近の棚卸日より前です」の警告が出てしまう
    it "1 件も数えていない棚卸は確定できない" do
      expect { finalize }.to raise_error(described_class::NothingCounted)
      expect(stock_take.reload.finalized_at).to be_nil
    end

    it "実数が未入力の明細しかなくても確定できない" do
      add_entry(counted: nil)

      expect { finalize }.to raise_error(described_class::NothingCounted)
    end

    # 同じ品目への同時操作を直列化する。ロックより前に書き込むと取りこぼす
    it "最初の書き込みより前に品目を行ロックする" do
      add_entry(counted: 7)
      stock_take.stock_take_entries.load

      statements = recorded_sql { finalize }

      expect(first_lock_index(statements)).not_to be_nil
      expect(first_lock_index(statements)).to be < first_write_index(statements)
    end

    # 途中で例外が起きて movement だけが残ると在庫が狂う
    it "途中で失敗したら movement も finalized_at も残らない (同一トランザクション)" do
      add_entry(counted: 7)
      allow(Stock::Recalculator).to receive(:call).and_raise("boom")

      expect {
        expect { finalize }.to raise_error("boom")
      }.not_to change { StockMovement.count }

      expect(stock_take.reload.finalized_at).to be_nil
    end
  end

  # Phase 7 のロットのガードが、棚卸のマイナス差分でも効いていること
  describe "Phase 7 のロットの制限" do
    let!(:lot) { create(:lot, item: item, initial_quantity: 10) }

    before do
      add_entry(counted: 7)
      finalize
    end

    it "棚卸のマイナス差分が紐づくロットは削除できない" do
      expect { Stock::DeleteLot.call(lot) }.not_to change { Lot.count }
      expect(lot.errors.full_messages.join).to include "削除できません"
    end

    it "既に引かれた数より小さい数量には編集できない" do
      revised = Stock::ReviseLot.call(lot, initial_quantity: 1)

      expect(revised.errors[:initial_quantity]).to be_present
      expect(item.reload.current_quantity).to eq 7
    end
  end

  # 画面は合計とロット別を両方は作らせないが、DB に両方あったら
  # より細かいロット別を採る (二重に数えない)
  describe "合計とロット別が共存したとき" do
    let(:item) { create(:item, :tracks_expiry, name: "たまご", unit: "個") }
    let!(:lot) { create(:lot, item: item, initial_quantity: 6) }

    it "ロット別だけを反映し、合計の明細は無視する" do
      total = add_entry(counted: 1)
      by_lot = add_entry(counted: 4, lot: lot)

      finalize

      expect(item.reload.current_quantity).to eq 4
      expect(by_lot.reload.stock_movements.sum(:quantity)).to eq(-2)
      expect(total.reload.stock_movements).to be_empty
    end
  end

  # 過去日の棚卸でも、movement の日付は棚卸日にそろえる
  it "プラス差分の movement と調整ロットの日付は棚卸日になる" do
    create(:lot, item: item, initial_quantity: 10)
    stock_take.update!(counted_on: Date.current - 4)
    entry = add_entry(counted: 12, expected: 10)

    finalize

    movement = entry.reload.stock_movements.sole
    expect(movement.occurred_on).to eq Date.current - 4
    expect(movement.lot.acquired_on).to eq Date.current - 4
  end
end
