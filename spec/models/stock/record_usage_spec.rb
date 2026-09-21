require "rails_helper"

RSpec.describe Stock::RecordUsage, type: :model do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:item) { create(:item, name: "トイレットペーパー", unit: "ロール") }
  let(:user) { create(:user) }

  def record(attributes = {})
    described_class.call(item: item, user: user,
      attributes: { quantity: 1, used_on: Date.current }.merge(attributes))
  end

  describe "使用の記録" do
    before { create(:lot, item: item, initial_quantity: 5) }

    it "UsageRecord が 1 件と StockMovement(usage, -1) が 1 件作られる" do
      expect { record }.to change { UsageRecord.count }.by(1)
        .and change { StockMovement.count }.by(1)

      movement = StockMovement.order(:id).last
      expect(movement).to be_kind_usage
      expect(movement.quantity).to eq(-1)
      expect(movement.item).to eq item
      expect(movement.user).to eq user
      expect(movement.usage_record).to eq UsageRecord.order(:id).last
    end

    it "在庫が減る" do
      record(quantity: 2)

      expect(item.reload.current_quantity).to eq 3
    end

    it "使用記録を作ると item.last_consumed_on が used_on になる" do
      record(used_on: Date.current - 1)

      expect(item.reload.last_consumed_on).to eq Date.current - 1
    end

    it "過去日 (3 日前) の使用記録でも現在庫は正しく減る" do
      record(quantity: 2, used_on: Date.current - 3)

      expect(item.reload.current_quantity).to eq 3
      expect(StockMovement.order(:id).last.occurred_on).to eq Date.current - 3
    end

    it "記録者は渡したユーザーになる" do
      expect(record.user).to eq user
    end

    it "メモも記録できる" do
      expect(record(note: "こぼした").note).to eq "こぼした"
    end

    it "在庫不足でなければ compensated_quantity は 0" do
      expect(record.compensated_quantity).to eq 0
    end
  end

  describe "FEFO の分割" do
    let!(:first) { create(:lot, item: item, initial_quantity: 2, expires_on: Date.current + 1) }
    let!(:second) { create(:lot, item: item, initial_quantity: 5, expires_on: Date.current + 30) }

    it "分割されても UsageRecord は 1 件、StockMovement は 2 件" do
      expect { record(quantity: 4) }.to change { UsageRecord.count }.by(1)
        .and change { StockMovement.count }.by(2)
    end

    it "期限が近いロットから順に引かれる" do
      usage = record(quantity: 4)

      expect(usage.stock_movements.order(:id).map(&:quantity)).to eq [ -2, -2 ]
      expect(first.reload.remaining_quantity).to eq 0
      expect(second.reload.remaining_quantity).to eq 3
      expect(item.reload.current_quantity).to eq 3
    end

    it "使い切ったロットには depleted_at が入る" do
      record(quantity: 4)

      expect(first.reload.depleted_at).to be_present
      expect(second.reload.depleted_at).to be_nil
    end
  end

  # 在庫記録が足りなくても「使った」は必ず成功させる (設計原則 3)
  describe "在庫不足の補填" do
    before { create(:lot, item: item, initial_quantity: 2) }

    it "在庫 2 に対して 3 使うと kind: adjustment のロットが 1 件作られる" do
      expect { record(quantity: 3) }.to change { Lot.count }.by(1)

      expect(Lot.order(:id).last).to be_kind_adjustment
      expect(Lot.order(:id).last.initial_quantity).to eq 1
    end

    it "補填した数を compensated_quantity で受け取れる" do
      expect(record(quantity: 3).compensated_quantity).to eq 1
    end

    it "補填の入庫 movement にも usage_record_id が入る" do
      usage = record(quantity: 3)

      compensating = usage.stock_movements.where(quantity: 1..).sole
      expect(compensating).to be_kind_adjustment
      expect(compensating.quantity).to eq 1
      expect(compensating.lot).to be_kind_adjustment
    end

    it "補填したロットからも同じ数だけ引かれ、在庫は 0 になる" do
      record(quantity: 3)

      expect(item.reload.current_quantity).to eq 0
      expect(Lot.order(:id).last.remaining_quantity).to eq 0
    end

    # 補填の入庫 (正の adjustment) を消費に数えると、予測のペースが狂う
    it "補填の入庫は消費に数えない (last_consumed_on は使用日のまま)" do
      record(quantity: 3, used_on: Date.current - 2)

      expect(item.reload.last_consumed_on).to eq Date.current - 2
    end
  end

  describe "用途" do
    let(:purpose) { create(:item_purpose, item: item, name: "リモコン") }

    before { create(:lot, item: item, initial_quantity: 5) }

    it "用途を指定した使用記録は item_purpose_id を持つ" do
      expect(record(item_purpose_id: purpose.id).item_purpose).to eq purpose
    end

    it "他の品目の用途は指定できず、何も作られない" do
      other = create(:item_purpose, item: create(:item))

      usage = nil
      expect { usage = record(item_purpose_id: other.id) }
        .not_to change { [ UsageRecord.count, StockMovement.count ] }
      expect(usage).not_to be_persisted
      expect(item.reload.current_quantity).to eq 5
    end
  end

  describe "ロットの手動指定" do
    let!(:near) { create(:lot, item: item, initial_quantity: 5, expires_on: Date.current + 1) }
    let!(:far) { create(:lot, item: item, initial_quantity: 5, expires_on: Date.current + 30) }

    it "指定したロットから引かれる" do
      record(quantity: 2, lot_id: far.id)

      expect(far.reload.remaining_quantity).to eq 3
      expect(near.reload.remaining_quantity).to eq 5
    end

    it "他の品目のロットは指定できず、何も作られない" do
      other_lot = create(:lot, item: create(:item), initial_quantity: 5)

      usage = nil
      expect { usage = record(lot_id: other_lot.id) }
        .not_to change { [ UsageRecord.count, StockMovement.count ] }
      expect(usage.errors[:lot_id]).to be_present
      expect(other_lot.reload.remaining_quantity).to eq 5
    end
  end

  describe "保存できない入力" do
    it "未来の日付では保存できず、UsageRecord も movement も作られない" do
      usage = nil

      travel_to Time.current.change(hour: 0, min: 10) do
        expect {
          usage = record(used_on: Date.current + 1)
        }.not_to change { [ UsageRecord.count, StockMovement.count, Lot.count ] }
      end

      expect(usage).not_to be_persisted
      expect(usage.errors[:used_on]).to be_present
    end

    it "数量が 0 なら保存できない (空とは違い、入力の誤りとして扱う)" do
      usage = nil

      expect { usage = record(quantity: 0) }.not_to change { UsageRecord.count }
      expect(usage.errors[:quantity]).to be_present
    end
  end

  # 「リモコンは 2 本」を JS 無しでも効かせる (docs/spec/03-screens.md 画面 4)
  describe "数量を空で送ったとき" do
    before { create(:lot, item: item, initial_quantity: 10) }

    it "用途なしなら 1 として記録される" do
      expect(record(quantity: nil).quantity).to eq 1
    end

    it "用途を選んでいればその用途の既定数量になる" do
      purpose = create(:item_purpose, item: item, name: "リモコン", default_quantity: 2)

      usage = record(quantity: nil, item_purpose_id: purpose.id)

      expect(usage.quantity).to eq 2
      expect(item.reload.current_quantity).to eq 8
    end

    it "数量を明示したらそちらが優先される" do
      purpose = create(:item_purpose, item: item, default_quantity: 2)

      expect(record(quantity: 5, item_purpose_id: purpose.id).quantity).to eq 5
    end
  end

  describe "キャッシュ列・品目・記録者は入力から受け取らない" do
    before { create(:lot, item: item, initial_quantity: 5) }

    it "item_id を渡しても、記録されるのは呼び出しで渡した品目" do
      other = create(:item)
      create(:lot, item: other, initial_quantity: 5)

      usage = record(item_id: other.id)

      expect(usage.item).to eq item
      expect(item.reload.current_quantity).to eq 4
      expect(other.reload.current_quantity).to eq 5
    end

    it "user_id を渡しても、記録者は呼び出しで渡したユーザー" do
      other = create(:user)

      expect(record(user_id: other.id).user).to eq user
    end
  end

  # 同じ品目への同時操作を直列化する。ロックより前に書き込むと取りこぼす
  it "最初の書き込みより前に品目を行ロックする" do
    # let は遅延評価なので、先に作っておかないと factory の INSERT まで記録してしまう
    item
    user
    create(:lot, item: item, initial_quantity: 5)
    statements = recorded_sql { record }

    expect(first_lock_index(statements)).not_to be_nil
    expect(first_lock_index(statements)).to be < first_write_index(statements)
  end

  # ロック待ちの間に別の画面で使われていることがある
  it "ロックの前に読んだ古い在庫では引き当てない" do
    lot = create(:lot, item: item, initial_quantity: 5)
    item.lots.load
    create(:stock_movement, lot: Lot.find(lot.id), kind: :usage, quantity: -4)
    Stock::Recalculator.call(Item.find(item.id))

    usage = record(quantity: 2)

    expect(usage.compensated_quantity).to eq 1
    expect(item.reload.current_quantity).to eq 0
  end

  describe "call と call!" do
    it "call は保存できなければ errors 入りの未保存レコードを返す" do
      usage = record(quantity: 0)

      expect(usage).not_to be_persisted
      expect(usage.errors).to be_present
    end

    # 内側の ActiveRecord::Rollback は内側の transaction に握りつぶされるので、
    # 入れ子で使うときは例外で外まで知らせる
    it "call! は保存できなければ ActiveRecord::RecordInvalid を上げる" do
      expect {
        described_class.call!(item: item, user: user,
          attributes: { quantity: 0, used_on: Date.current })
      }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "call! は保存できれば UsageRecord を返す" do
      create(:lot, item: item, initial_quantity: 5)

      usage = described_class.call!(item: item, user: user,
        attributes: { quantity: 1, used_on: Date.current })

      expect(usage).to be_persisted
    end

    it "外側のトランザクションから call! を呼ぶと、外側ごとロールバックできる" do
      expect {
        ApplicationRecord.transaction do
          create(:lot, item: item, initial_quantity: 5)
          described_class.call!(item: item, user: user,
            attributes: { quantity: 0, used_on: Date.current })
        end
      }.to raise_error(ActiveRecord::RecordInvalid)

      expect(Lot.count).to eq 0
    end
  end

  # 途中で例外が起きたときに movement だけが残ると在庫が狂う
  it "再計算が失敗したら UsageRecord も movement も残らない (同一トランザクション)" do
    create(:lot, item: item, initial_quantity: 5)
    allow(Stock::Recalculator).to receive(:call).and_raise("boom")

    expect {
      expect { record }.to raise_error("boom")
    }.not_to change { [ UsageRecord.count, StockMovement.count ] }
  end

  # Phase 7 で入れたロットのガードが、実際の使用記録でも効いていること
  describe "Phase 7 のロットの制限" do
    let!(:lot) { create(:lot, item: item, initial_quantity: 5) }

    before { record(quantity: 2) }

    it "使用の記録が紐づくロットは削除できない" do
      expect { Stock::DeleteLot.call(lot) }.not_to change { Lot.count }
      expect(lot.errors.full_messages.join).to include "削除できません"
    end

    it "既に使われた数より小さい数量には編集できない" do
      revised = Stock::ReviseLot.call(lot, initial_quantity: 1)

      expect(revised.errors[:initial_quantity]).to be_present
      expect(lot.reload.initial_quantity).to eq 5
      expect(item.reload.current_quantity).to eq 3
    end

    it "使われた数以上なら編集できる" do
      Stock::ReviseLot.call(lot, initial_quantity: 2)

      expect(lot.reload.initial_quantity).to eq 2
      expect(item.reload.current_quantity).to eq 0
    end
  end
end
