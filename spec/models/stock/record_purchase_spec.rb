require "rails_helper"

RSpec.describe Stock::RecordPurchase, type: :model do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:item) { create(:item, unit: "ロール") }
  let(:user) { create(:user) }

  def record(attributes = {})
    described_class.call(item: item, user: user,
      attributes: { acquired_on: Date.current, initial_quantity: 12 }.merge(attributes))
  end

  describe "購入の記録" do
    it "Lot が 1 件と StockMovement(purchase, +12) が 1 件作られる" do
      expect { record }.to change { Lot.count }.by(1).and change { StockMovement.count }.by(1)

      movement = StockMovement.order(:id).last
      expect(movement).to be_kind_purchase
      expect(movement.quantity).to eq 12
      expect(movement.lot).to eq Lot.order(:id).last
      expect(movement.item).to eq item
      expect(movement.user).to eq user
    end

    it "movement の occurred_on は購入日になる" do
      lot = record(acquired_on: Date.current - 3)

      expect(lot.stock_movements.sole.occurred_on).to eq Date.current - 3
    end

    it "lot.remaining_quantity が 12 になる" do
      lot = record

      expect(lot.reload.remaining_quantity).to eq 12
    end

    it "item.current_quantity が 12 になる" do
      record

      expect(item.reload.current_quantity).to eq 12
    end

    it "2 回購入すると item.current_quantity は合計になる" do
      record(initial_quantity: 12)
      record(initial_quantity: 3)

      expect(item.reload.current_quantity).to eq 15
    end

    it "item.tracking_started_on は最も古い購入日になる" do
      record(acquired_on: Date.current)
      record(acquired_on: Date.current - 30)

      expect(item.reload.tracking_started_on).to eq Date.current - 30
    end

    it "入庫だけでは last_consumed_on は入らない" do
      record

      expect(item.reload.last_consumed_on).to be_nil
    end

    it "記録者は渡したユーザーになる" do
      lot = record

      expect(lot.user).to eq user
    end

    it "入数 12 × パック数 2 なら数量 24 のロットになる" do
      lot = record(pack_size: 12, pack_count: 2, initial_quantity: nil)

      expect(lot.initial_quantity).to eq 24
      expect(lot.stock_movements.sole.quantity).to eq 24
      expect(item.reload.current_quantity).to eq 24
    end

    it "店舗・金額・期限・メモも記録できる" do
      store = create(:store)
      lot = record(store: store, price_yen: 456, expires_on: Date.current + 30, note: "特売")

      expect(lot.store).to eq store
      expect(lot.price_yen).to eq 456
      expect(lot.expires_on).to eq Date.current + 30
      expect(lot.note).to eq "特売"
    end
  end

  # すべての入庫がロットを作る (docs/spec/01-domain-model.md 判断 2)。
  # 初期在庫も同じ経路を通り、movement の kind は purchase のまま
  describe "初期在庫 (kind: initial)" do
    it "kind: initial のロットができ、movement は purchase になる" do
      lot = record(kind: :initial)

      expect(lot).to be_kind_initial
      expect(lot.stock_movements.sole).to be_kind_purchase
      expect(item.reload.current_quantity).to eq 12
    end
  end

  describe "保存できない入力" do
    it "未来の日付では保存できず、Lot も movement も作られない" do
      lot = nil

      travel_to Time.zone.parse("2026-09-20 00:10") do
        expect {
          lot = record(acquired_on: Date.current + 1)
        }.not_to change { [ Lot.count, StockMovement.count ] }
      end

      expect(lot).not_to be_persisted
      expect(lot.errors[:acquired_on]).to be_present
      expect(item.reload.current_quantity).to eq 0
    end

    it "数量が空なら保存できない" do
      lot = nil

      expect { lot = record(initial_quantity: nil) }.not_to change { Lot.count }
      expect(lot.errors[:initial_quantity]).to be_present
    end

    it "数量が 0 なら保存できない" do
      expect { record(initial_quantity: 0) }.not_to change { Lot.count }
    end

    it "削除済みの店舗 id では保存できない (外部キー違反で 500 にしない)" do
      store = create(:store)
      store_id = store.id
      store.destroy

      lot = nil
      expect { lot = record(store_id: store_id) }.not_to change { Lot.count }
      expect(lot.errors[:store]).to be_present
    end
  end

  describe "キャッシュ列は入力から受け取らない" do
    it "remaining_quantity を渡しても台帳から再計算した値になる" do
      lot = record(initial_quantity: 12, remaining_quantity: 999)

      expect(lot.reload.remaining_quantity).to eq 12
    end

    it "depleted_at を渡しても無視される" do
      lot = record(depleted_at: Time.current)

      expect(lot.reload.depleted_at).to be_nil
    end

    it "item_id を渡しても、記録されるのは呼び出しで渡した品目" do
      other = create(:item)

      lot = record(item_id: other.id)

      expect(lot.item).to eq item
      expect(item.reload.current_quantity).to eq 12
      expect(other.reload.current_quantity).to eq 0
    end
  end

  # 同じ品目への同時操作を直列化する。ロックより前に書き込むと取りこぼす
  it "最初の書き込みより前に品目を行ロックする" do
    # let は遅延評価なので、先に作っておかないと factory の INSERT まで記録してしまう
    item
    user
    statements = recorded_sql { record }

    expect(first_lock_index(statements)).not_to be_nil
    expect(first_lock_index(statements)).to be < first_write_index(statements)
  end

  # まとめ購入 (Stock::RecordBulkPurchase) が入れ子で呼ぶ。
  # 内側の ActiveRecord::Rollback は外側のトランザクションに届かないので例外にする
  describe ".call!" do
    it "保存できれば Lot を返す" do
      lot = described_class.call!(item: item, user: user,
        attributes: { acquired_on: Date.current, initial_quantity: 3 })

      expect(lot).to be_persisted
    end

    it "保存できなければ ActiveRecord::RecordInvalid を上げ、エラー付きの Lot を持たせる" do
      expect {
        described_class.call!(item: item, user: user,
          attributes: { acquired_on: Date.current, initial_quantity: 0 })
      }.to raise_error(ActiveRecord::RecordInvalid) { |error|
        expect(error.record.errors[:initial_quantity]).to be_present
      }
    end

    it "外側のトランザクションから見て、失敗した入庫が残らない" do
      # let は遅延評価なので、先に作っておかないと品目と記録者までロールバックで消える
      item
      user

      expect {
        ApplicationRecord.transaction do
          described_class.call!(item: item, user: user,
            attributes: { acquired_on: Date.current, initial_quantity: 5 })
          described_class.call!(item: item, user: user,
            attributes: { acquired_on: Date.current, initial_quantity: 0 })
        end
      }.to raise_error(ActiveRecord::RecordInvalid)

      expect(Lot.count).to eq 0
      expect(item.reload.current_quantity).to eq 0
    end
  end

  # 途中で例外が起きたときに Lot だけ・movement だけが残ると在庫が狂う
  it "再計算が失敗したら Lot も movement も残らない (同一トランザクション)" do
    allow(Stock::Recalculator).to receive(:call).and_raise("boom")

    expect {
      expect { record }.to raise_error("boom")
    }.not_to change { [ Lot.count, StockMovement.count ] }
  end
end
