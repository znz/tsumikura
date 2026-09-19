require "rails_helper"

RSpec.describe Stock::DeleteMovement, type: :model do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:item) { create(:item, name: "トイレットペーパー", unit: "ロール") }
  let(:user) { create(:user) }

  def record(attributes = {})
    Stock::RecordUsage.call(item: item, user: user,
      attributes: { quantity: 2, used_on: Date.current }.merge(attributes))
  end

  describe "使用記録の削除" do
    let!(:lot) { create(:lot, item: item, initial_quantity: 10) }

    it "在庫が戻り、UsageRecord と StockMovement が消える" do
      usage = record(quantity: 2)

      expect { described_class.call(usage) }
        .to change { UsageRecord.count }.by(-1)
        .and change { StockMovement.count }.by(-1)

      expect(usage).to be_destroyed
      expect(item.reload.current_quantity).to eq 10
      expect(lot.reload.remaining_quantity).to eq 10
    end

    it "分割された StockMovement もすべて消える" do
      create(:lot, item: item, initial_quantity: 1, expires_on: Date.current + 1)
      usage = record(quantity: 3)
      expect(usage.stock_movements.count).to eq 2

      expect { described_class.call(usage) }.to change { StockMovement.count }.by(-2)
      expect(item.reload.current_quantity).to eq 11
    end

    it "使い切ったロットの depleted_at も消える" do
      usage = record(quantity: 10)
      expect(lot.reload.depleted_at).to be_present

      described_class.call(usage)

      expect(lot.reload.depleted_at).to be_nil
    end

    it "最新の使用記録を削除すると last_consumed_on は 1 つ前の消費日に戻る" do
      record(quantity: 1, used_on: Date.current - 5)
      latest = record(quantity: 1, used_on: Date.current)
      expect(item.reload.last_consumed_on).to eq Date.current

      described_class.call(latest)

      expect(item.reload.last_consumed_on).to eq Date.current - 5
    end

    it "最後の使用記録を削除すると last_consumed_on は nil に戻る" do
      usage = record(quantity: 1)

      described_class.call(usage)

      expect(item.reload.last_consumed_on).to be_nil
    end

    it "他の使用記録の movement は消えない" do
      kept = record(quantity: 1)
      removed = record(quantity: 3)

      described_class.call(removed)

      expect(kept.reload.stock_movements.count).to eq 1
      expect(item.reload.current_quantity).to eq 9
    end
  end

  # 補填で作った調整ロットは、movement が無くなると実在しない在庫の空き箱になる
  describe "補填の調整ロットの後始末" do
    it "在庫不足で作られた調整ロットも一緒に消える" do
      usage = record(quantity: 3)
      expect(usage.compensated_quantity).to eq 3
      expect(item.lots.where(kind: :adjustment).count).to eq 1

      expect { described_class.call(usage) }.to change { Lot.count }.by(-1)

      expect(item.reload.current_quantity).to eq 0
      expect(item.lots).to be_empty
    end

    it "一部だけ補填していた場合も、調整ロットだけが消えて購入のロットは残る" do
      lot = create(:lot, item: item, initial_quantity: 2)
      usage = record(quantity: 3)

      expect { described_class.call(usage) }.to change { Lot.count }.by(-1)

      expect(Lot.exists?(lot.id)).to be true
      expect(item.reload.current_quantity).to eq 2
    end

    # 棚卸 (Phase 9) のプラス差分で作られた調整ロットには、使用記録に紐づかない
    # 入庫 movement が残るので消してはいけない
    it "使用記録に紐づかない入庫がある調整ロットは消さない" do
      adjustment_lot = create(:lot, :adjustment, item: item, initial_quantity: 5)
      usage = record(quantity: 2)

      expect { described_class.call(usage) }.not_to change { Lot.count }

      expect(adjustment_lot.reload.remaining_quantity).to eq 5
      expect(item.reload.current_quantity).to eq 5
    end
  end

  # 同じ品目への同時操作を直列化する
  it "最初の書き込みより前に品目を行ロックする" do
    create(:lot, item: item, initial_quantity: 10)
    usage = record(quantity: 2)
    statements = recorded_sql { described_class.call(usage) }

    expect(first_lock_index(statements)).not_to be_nil
    expect(first_lock_index(statements)).to be < first_write_index(statements)
  end

  it "別の画面で先に削除されていたら RecordNotFound になる (「削除しました」と嘘をつかない)" do
    create(:lot, item: item, initial_quantity: 10)
    usage = record
    described_class.call(UsageRecord.find(usage.id))

    expect { described_class.call(usage) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "途中で例外が起きたら記録も movement も消えない (同一トランザクション)" do
    create(:lot, item: item, initial_quantity: 10)
    usage = record(quantity: 2)
    allow(Stock::Recalculator).to receive(:call).and_raise("boom")

    expect {
      expect { described_class.call(usage) }.to raise_error("boom")
    }.not_to change { [ UsageRecord.count, StockMovement.count ] }

    expect(item.reload.current_quantity).to eq 8
  end
end
