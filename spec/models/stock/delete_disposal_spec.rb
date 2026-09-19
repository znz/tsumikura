require "rails_helper"

RSpec.describe Stock::DeleteDisposal, type: :model do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:item) { create(:item, name: "たまご", unit: "個") }
  let(:user) { create(:user) }
  let!(:lot) { create(:lot, item: item, initial_quantity: 5) }

  def dispose(quantity: 2)
    Stock::RecordDisposal.call(item: item, user: user, attributes: {
      quantity: quantity, occurred_on: Date.current, disposal_reason: "expired"
    }).movements.sole
  end

  it "廃棄を取り消すと在庫が戻る" do
    movement = dispose

    expect { described_class.call(movement) }.to change { StockMovement.count }.by(-1)
    expect(movement).to be_destroyed
    expect(item.reload.current_quantity).to eq 5
    expect(lot.reload.remaining_quantity).to eq 5
  end

  it "使い切ったロットの depleted_at も消える" do
    movement = dispose(quantity: 5)
    expect(lot.reload.depleted_at).to be_present

    described_class.call(movement)

    expect(lot.reload.depleted_at).to be_nil
  end

  # 廃棄は消費に数えないので、取り消しても予測のアンカーは動かない
  it "item.last_consumed_on は使用の記録のままになる" do
    Stock::RecordUsage.call(item: item, user: user,
      attributes: { quantity: 1, used_on: Date.current - 1 })
    movement = dispose(quantity: 1)

    described_class.call(movement)

    expect(item.reload.last_consumed_on).to eq Date.current - 1
  end

  it "最初の書き込みより前に品目を行ロックする" do
    movement = dispose

    statements = recorded_sql { described_class.call(movement) }

    expect(first_lock_index(statements)).not_to be_nil
    expect(first_lock_index(statements)).to be < first_write_index(statements)
  end

  # 別の画面で先に取り消されていたら「削除しました」と嘘をつかない
  it "ロック待ちの間に消されていたら RecordNotFound になる" do
    movement = dispose
    StockMovement.find(movement.id).delete

    expect { described_class.call(movement) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "再計算が失敗したら movement も消えない (同一トランザクション)" do
    movement = dispose
    allow(Stock::Recalculator).to receive(:call).and_raise("boom")

    expect {
      expect { described_class.call(movement) }.to raise_error("boom")
    }.not_to change { StockMovement.count }
  end
end
