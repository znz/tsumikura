require "rails_helper"

RSpec.describe Stock::ReviseUsage, type: :model do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:item) { create(:item, name: "トイレットペーパー", unit: "ロール") }
  let(:user) { create(:user) }
  let!(:lot) { create(:lot, item: item, initial_quantity: 10) }

  def record(attributes = {})
    Stock::RecordUsage.call(item: item, user: user,
      attributes: { quantity: 2, used_on: Date.current }.merge(attributes))
  end

  describe "数量の編集" do
    it "増やすと在庫が減り、movement も作り直される" do
      usage = record(quantity: 2)

      described_class.call(usage, quantity: 5)

      expect(usage.reload.quantity).to eq 5
      expect(usage.stock_movements.sum(:quantity)).to eq(-5)
      expect(item.reload.current_quantity).to eq 5
    end

    it "減らすと在庫が戻る" do
      usage = record(quantity: 5)

      described_class.call(usage, quantity: 1)

      expect(item.reload.current_quantity).to eq 9
    end

    # 古い movement を消して在庫を戻す「前」に引き当てると、自分がさっき引いた分が
    # 在庫に無いものとして扱われ、要らない補填が作られてしまう
    it "自分が引いていた分を戻してから引き当てる (補填しない)" do
      small = create(:item)
      create(:lot, item: small, initial_quantity: 5)
      usage = Stock::RecordUsage.call(item: small, user: user,
        attributes: { quantity: 4, used_on: Date.current })

      expect { described_class.call(usage, quantity: 5) }.not_to change { Lot.count }

      expect(usage.compensated_quantity).to eq 0
      expect(small.reload.current_quantity).to eq 0
    end

    it "在庫を超えて増やすと補填が増え、調整ロットは 1 件のまま" do
      small = create(:item)
      create(:lot, item: small, initial_quantity: 2)
      usage = Stock::RecordUsage.call(item: small, user: user,
        attributes: { quantity: 3, used_on: Date.current })
      expect(usage.compensated_quantity).to eq 1

      described_class.call(usage, quantity: 5)

      adjustment = small.lots.where(kind: :adjustment).sole
      expect(adjustment.initial_quantity).to eq 3
      expect(usage.compensated_quantity).to eq 3
      expect(small.reload.current_quantity).to eq 0
    end

    it "数量を変えなければ在庫も変わらない" do
      usage = record(quantity: 2)

      described_class.call(usage, quantity: 2, note: "書き直し")

      expect(item.reload.current_quantity).to eq 8
      expect(usage.reload.note).to eq "書き直し"
    end
  end

  describe "日付の編集" do
    it "movement の occurred_on も直り、last_consumed_on が追随する" do
      usage = record(used_on: Date.current)

      described_class.call(usage, used_on: Date.current - 5)

      expect(usage.reload.stock_movements.pluck(:occurred_on).uniq).to eq [ Date.current - 5 ]
      expect(item.reload.last_consumed_on).to eq Date.current - 5
    end

    it "未来の日付には編集できず、在庫も movement も変わらない" do
      usage = record(quantity: 2)

      travel_to Time.zone.parse("2026-09-20 00:10") do
        expect {
          described_class.call(usage, used_on: Date.current + 1)
        }.not_to change { StockMovement.count }
      end

      expect(usage.reload.used_on).to eq Date.current
      expect(item.reload.current_quantity).to eq 8
    end
  end

  describe "用途の編集" do
    it "用途を付け替えられる" do
      purpose = create(:item_purpose, item: item, name: "リモコン")
      usage = record

      described_class.call(usage, item_purpose_id: purpose.id)

      expect(usage.reload.item_purpose).to eq purpose
    end

    it "用途を外せる" do
      purpose = create(:item_purpose, item: item)
      usage = record(item_purpose_id: purpose.id)

      described_class.call(usage, item_purpose_id: "")

      expect(usage.reload.item_purpose).to be_nil
    end

    it "他の品目の用途には付け替えられず、在庫も動かない" do
      other = create(:item_purpose, item: create(:item))
      usage = record(quantity: 2)

      described_class.call(usage, item_purpose_id: other.id)

      expect(usage.reload.item_purpose).to be_nil
      expect(item.reload.current_quantity).to eq 8
    end
  end

  describe "引き当て先ロットの編集" do
    let!(:other_lot) { create(:lot, item: item, initial_quantity: 4, expires_on: Date.current + 60) }

    it "ロットを指定し直すと、そのロットから引き直される" do
      # 自動引き当てでは期限つきの other_lot が先に引かれる (FEFO)
      usage = record(quantity: 2)
      expect(other_lot.reload.remaining_quantity).to eq 2

      described_class.call(usage, quantity: 2, lot_id: lot.id)

      expect(other_lot.reload.remaining_quantity).to eq 4
      expect(lot.reload.remaining_quantity).to eq 8
      expect(item.reload.current_quantity).to eq 12
    end

    it "手動で指定した記録を数量だけ編集しても、指定したロットが優先される" do
      usage = record(quantity: 2, lot_id: lot.id)
      expect(lot.reload.remaining_quantity).to eq 8

      described_class.call(usage, quantity: 3)

      expect(lot.reload.remaining_quantity).to eq 7
      expect(other_lot.reload.remaining_quantity).to eq 4
    end
  end

  # movement を作り直すからといって、引き当て直しで別のロットに移ってはいけない。
  # ロット別の残数が変わると「実物があるロットが depleted になる」「期限切れかどうかが
  # 変わって要購入判定の在庫 q が動く」といった実害が出る
  describe "元のロットの優先" do
    let!(:near) { create(:lot, item: item, initial_quantity: 1, expires_on: Date.current + 1) }
    let!(:far) { create(:lot, item: item, initial_quantity: 5, expires_on: Date.current + 60) }

    it "メモだけの編集ではロット別の残数が変わらない" do
      usage = record(quantity: 1, lot_id: far.id)
      expect(far.reload.remaining_quantity).to eq 4

      described_class.call(usage, note: "書き直し")

      expect(near.reload.remaining_quantity).to eq 1
      expect(far.reload.remaining_quantity).to eq 4
      expect(near.reload.depleted_at).to be_nil
    end

    it "用途だけの編集でもロット別の残数が変わらない" do
      purpose = create(:item_purpose, item: item, name: "来客用")
      usage = record(quantity: 1, lot_id: far.id)

      described_class.call(usage, item_purpose_id: purpose.id)

      expect(far.reload.remaining_quantity).to eq 4
      expect(near.reload.remaining_quantity).to eq 1
    end

    it "分割された記録のメモだけ直しても、分け方が変わらない" do
      usage = record(quantity: 3)
      expect([ near.reload.remaining_quantity, far.reload.remaining_quantity ]).to eq [ 0, 3 ]

      described_class.call(usage, note: "書き直し")

      expect(near.reload.remaining_quantity).to eq 0
      expect(far.reload.remaining_quantity).to eq 3
      expect(usage.reload.stock_movements.order(:id).map(&:quantity)).to eq [ -1, -2 ]
    end
  end

  # 補填の調整ロットは、その使用記録を編集したときに一緒に片づける
  # (残しておくと実在しない在庫を持つ空のロットが積み上がる)
  describe "補填の調整ロットの後始末" do
    let(:empty_item) { create(:item, name: "在庫なし品目") }

    it "在庫が足りて補填が要らなくなったら、調整ロットごと消える" do
      usage = Stock::RecordUsage.call(item: empty_item, user: user,
        attributes: { quantity: 3, used_on: Date.current })
      expect(usage.compensated_quantity).to eq 3
      create(:lot, item: empty_item, initial_quantity: 10)

      expect { described_class.call(usage, quantity: 3) }.to change { Lot.count }.by(-1)

      expect(empty_item.reload.current_quantity).to eq 7
      expect(empty_item.lots.where(kind: :adjustment)).to be_empty
    end

    it "補填が減れば、調整ロットも新しい数量で作り直される" do
      usage = Stock::RecordUsage.call(item: empty_item, user: user,
        attributes: { quantity: 3, used_on: Date.current })

      described_class.call(usage, quantity: 1)

      adjustment = empty_item.lots.where(kind: :adjustment).sole
      expect(adjustment.initial_quantity).to eq 1
      expect(usage.compensated_quantity).to eq 1
      expect(empty_item.reload.current_quantity).to eq 0
    end
  end

  describe "編集できない項目" do
    it "品目は変えられない" do
      other = create(:item)
      usage = record(quantity: 2)

      described_class.call(usage, item_id: other.id, quantity: 2)

      expect(usage.reload.item).to eq item
      expect(other.reload.current_quantity).to eq 0
      expect(item.reload.current_quantity).to eq 8
    end

    it "記録者は変えられない" do
      other = create(:user)
      usage = record

      described_class.call(usage, user_id: other.id)

      expect(usage.reload.user).to eq user
    end
  end

  # 同じ品目への同時操作を直列化する
  it "最初の書き込みより前に品目を行ロックする" do
    usage = record(quantity: 2)
    statements = recorded_sql { described_class.call(usage, quantity: 3) }

    expect(first_lock_index(statements)).not_to be_nil
    expect(first_lock_index(statements)).to be < first_write_index(statements)
  end

  # ロック待ちの間に別の画面で編集されていることがある
  it "ロックの前に読んだ古い値ではなく、読み直した値を書き換える" do
    usage = record(quantity: 2)
    UsageRecord.find(usage.id).update_columns(note: "別の画面のメモ")

    described_class.call(usage, quantity: 3)

    expect(usage.reload.note).to eq "別の画面のメモ"
    expect(usage.quantity).to eq 3
  end

  it "別の画面で先に削除されていたら RecordNotFound になる" do
    usage = record
    Stock::DeleteMovement.call(UsageRecord.find(usage.id))

    expect { described_class.call(usage, quantity: 3) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end

  describe "call と call!" do
    it "call は保存できなければ errors 入りのレコードを返し、在庫も変わらない" do
      usage = record(quantity: 2)

      revised = described_class.call(usage, quantity: 0)

      expect(revised.errors[:quantity]).to be_present
      expect(usage.reload.quantity).to eq 2
      expect(item.reload.current_quantity).to eq 8
    end

    it "call! は保存できなければ ActiveRecord::RecordInvalid を上げる" do
      usage = record(quantity: 2)

      expect { described_class.call!(usage, quantity: 0) }
        .to raise_error(ActiveRecord::RecordInvalid)
    end
  end
end
