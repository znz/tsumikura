require "rails_helper"

RSpec.describe Stock::DeleteLot, type: :model do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:item) { create(:item) }
  let(:lot) { create(:lot, item: item, initial_quantity: 12) }

  it "購入記録を削除すると Lot と movement が消えて在庫が元に戻る" do
    lot

    expect { described_class.call(lot) }
      .to change { Lot.count }.by(-1)
      .and change { StockMovement.count }.by(-1)

    expect(item.reload.current_quantity).to eq 0
  end

  it "他のロットの在庫は残る" do
    lot
    create(:lot, item: item, initial_quantity: 3)

    described_class.call(lot)

    expect(item.reload.current_quantity).to eq 3
  end

  it "最後の購入記録を削除すると tracking_started_on が nil に戻る" do
    lot

    described_class.call(lot)

    expect(item.reload.tracking_started_on).to be_nil
  end

  it "削除できたかは destroyed? で分かる" do
    expect(described_class.call(lot)).to be_destroyed
  end

  describe "使用の記録が紐づくロット" do
    before do
      create(:stock_movement, lot: lot, kind: :usage, quantity: -5)
      Stock::Recalculator.call(item)
    end

    it "削除できず、在庫も変わらない" do
      expect { described_class.call(lot) }.not_to change { Lot.count }

      expect(lot.reload.remaining_quantity).to eq 7
      expect(item.reload.current_quantity).to eq 7
    end

    it "使用の記録も消えない" do
      expect { described_class.call(lot) }.not_to change { StockMovement.count }
    end
  end

  describe "ロックの前に読んだロット" do
    it "別の画面で使用が記録されていたら削除しない" do
      stale = Lot.find(lot.id)
      create(:stock_movement, lot: Lot.find(lot.id), kind: :usage, quantity: -1)

      described_class.call(stale)

      expect(Lot.exists?(lot.id)).to be true
      expect(stale).not_to be_destroyed
    end

    # ロックの中で読み直さないと、既に消えているロットを「削除しました」と報告してしまう
    it "別の画面で先に削除されていたら RecordNotFound になる" do
      stale = Lot.find(lot.id)
      described_class.call(Lot.find(lot.id))

      expect { described_class.call(stale) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  it "最初の書き込みより前に品目を行ロックする" do
    lot
    statements = recorded_sql { described_class.call(lot) }

    expect(first_lock_index(statements)).not_to be_nil
    expect(first_lock_index(statements)).to be < first_write_index(statements)
  end

  it "再計算が失敗したら削除も取り消される" do
    lot
    allow(Stock::Recalculator).to receive(:call).and_raise("boom")

    expect { described_class.call(lot) }.to raise_error("boom")

    expect(Lot.exists?(lot.id)).to be true
    expect(item.reload.current_quantity).to eq 12
  end
end
