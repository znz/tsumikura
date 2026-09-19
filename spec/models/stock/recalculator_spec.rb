require "rails_helper"

# 在庫の正は stock_movements の総和で、lots.remaining_quantity / items.current_quantity /
# items.tracking_started_on / items.last_consumed_on は再計算できるキャッシュである
# (docs/spec/01-domain-model.md 判断 1)。
RSpec.describe Stock::Recalculator, type: :model do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:item) { create(:item) }
  let(:user) { create(:user) }

  # 台帳だけを作る (キャッシュは既定値のまま) ヘルパー
  def add_movement(lot, kind:, quantity:, occurred_on: Date.current)
    lot.stock_movements.create!(item: lot.item, user: user, kind: kind,
      quantity: quantity, occurred_on: occurred_on)
  end

  describe "ロットの残数" do
    it "movements の総和になる" do
      lot = create(:lot, item: item, initial_quantity: 12, with_movement: false)
      add_movement(lot, kind: :purchase, quantity: 12)
      add_movement(lot, kind: :usage, quantity: -5)

      described_class.call(item)

      expect(lot.reload.remaining_quantity).to eq 7
    end

    it "movements が 1 件も無ければ 0 になる" do
      lot = create(:lot, item: item, initial_quantity: 12, with_movement: false)

      described_class.call(item)

      expect(lot.reload.remaining_quantity).to eq 0
    end

    it "キャッシュが多すぎても台帳の値に戻す" do
      lot = create(:lot, item: item, initial_quantity: 12)
      lot.update_column(:remaining_quantity, 99)

      described_class.call(item)

      expect(lot.reload.remaining_quantity).to eq 12
    end

    it "キャッシュが少なすぎても台帳の値に戻す" do
      lot = create(:lot, item: item, initial_quantity: 12)
      lot.update_column(:remaining_quantity, 0)

      described_class.call(item)

      expect(lot.reload.remaining_quantity).to eq 12
    end

    it "他の品目のロットには触らない" do
      other_lot = create(:lot, initial_quantity: 3)
      other_lot.update_column(:remaining_quantity, 99)

      described_class.call(item)

      expect(other_lot.reload.remaining_quantity).to eq 99
    end
  end

  describe "depleted_at" do
    it "残 0 になったロットには depleted_at を打つ" do
      lot = create(:lot, item: item, initial_quantity: 3)
      add_movement(lot, kind: :usage, quantity: -3)

      described_class.call(item)

      expect(lot.reload.remaining_quantity).to eq 0
      expect(lot.depleted_at).to be_present
    end

    it "残があるロットには depleted_at を打たない" do
      lot = create(:lot, item: item, initial_quantity: 3)
      add_movement(lot, kind: :usage, quantity: -1)

      described_class.call(item)

      expect(lot.reload.depleted_at).to be_nil
    end

    it "残が戻ったロットの depleted_at は消す (記録の削除・編集で戻ることがある)" do
      lot = create(:lot, item: item, initial_quantity: 3)
      usage = add_movement(lot, kind: :usage, quantity: -3)
      described_class.call(item)

      usage.destroy
      described_class.call(item)

      expect(lot.reload.depleted_at).to be_nil
      expect(lot.remaining_quantity).to eq 3
    end

    it "再計算しても depleted_at の日時は上書きしない" do
      lot = create(:lot, item: item, initial_quantity: 3)
      add_movement(lot, kind: :usage, quantity: -3)
      described_class.call(item)
      depleted_at = lot.reload.depleted_at

      travel_to 1.hour.from_now do
        described_class.call(item)
      end

      expect(lot.reload.depleted_at).to eq depleted_at
    end
  end

  describe "品目の在庫数" do
    it "全ロットの残数の合計になる" do
      create(:lot, item: item, initial_quantity: 12)
      create(:lot, item: item, initial_quantity: 3)

      described_class.call(item)

      expect(item.reload.current_quantity).to eq 15
    end

    it "キャッシュがずれていても台帳から正しい値に戻す" do
      create(:lot, item: item, initial_quantity: 12)
      item.update_column(:current_quantity, 99)

      described_class.call(item)

      expect(item.reload.current_quantity).to eq 12
    end

    it "ロットが 1 件も無ければ 0 になる" do
      item.update_column(:current_quantity, 5)

      described_class.call(item)

      expect(item.reload.current_quantity).to eq 0
    end

    it "他の品目の在庫は混ざらない" do
      create(:lot, item: item, initial_quantity: 12)
      create(:lot, initial_quantity: 100)

      described_class.call(item)

      expect(item.reload.current_quantity).to eq 12
    end
  end

  describe "tracking_started_on" do
    it "最も古い movement の occurred_on になる" do
      lot = create(:lot, item: item, initial_quantity: 12, acquired_on: Date.current - 10)
      add_movement(lot, kind: :usage, quantity: -1, occurred_on: Date.current - 30)

      described_class.call(item)

      expect(item.reload.tracking_started_on).to eq Date.current - 30
    end

    it "あとから古い記録を足すと、より古い日に戻る" do
      lot = create(:lot, item: item, initial_quantity: 12, acquired_on: Date.current - 3)
      described_class.call(item)
      expect(item.reload.tracking_started_on).to eq Date.current - 3

      add_movement(lot, kind: :usage, quantity: -1, occurred_on: Date.current - 100)
      described_class.call(item)

      expect(item.reload.tracking_started_on).to eq Date.current - 100
    end

    it "movements が 1 件も無ければ nil になる" do
      item.update_column(:tracking_started_on, Date.current)

      described_class.call(item)

      expect(item.reload.tracking_started_on).to be_nil
    end
  end

  describe "last_consumed_on" do
    it "使用の最新日になる" do
      lot = create(:lot, item: item, initial_quantity: 12)
      add_movement(lot, kind: :usage, quantity: -1, occurred_on: Date.current - 5)
      add_movement(lot, kind: :usage, quantity: -1, occurred_on: Date.current - 2)

      described_class.call(item)

      expect(item.reload.last_consumed_on).to eq Date.current - 2
    end

    it "棚卸のマイナス差分 (負の adjustment) も消費に数える" do
      lot = create(:lot, item: item, initial_quantity: 12)
      add_movement(lot, kind: :adjustment, quantity: -2, occurred_on: Date.current - 1)

      described_class.call(item)

      expect(item.reload.last_consumed_on).to eq Date.current - 1
    end

    it "廃棄は消費に数えない" do
      lot = create(:lot, item: item, initial_quantity: 12)
      add_movement(lot, kind: :usage, quantity: -1, occurred_on: Date.current - 5)
      add_movement(lot, kind: :disposal, quantity: -1, occurred_on: Date.current)

      described_class.call(item)

      expect(item.reload.last_consumed_on).to eq Date.current - 5
    end

    it "入庫 (purchase) とプラスの調整は消費に数えない" do
      lot = create(:lot, item: item, initial_quantity: 12, acquired_on: Date.current)
      add_movement(lot, kind: :adjustment, quantity: 2, occurred_on: Date.current)

      described_class.call(item)

      expect(item.reload.last_consumed_on).to be_nil
    end

    it "最後の使用記録が消えると 1 つ前の消費日に戻る" do
      lot = create(:lot, item: item, initial_quantity: 12)
      add_movement(lot, kind: :usage, quantity: -1, occurred_on: Date.current - 5)
      latest = add_movement(lot, kind: :usage, quantity: -1, occurred_on: Date.current - 2)
      described_class.call(item)

      latest.destroy
      described_class.call(item)

      expect(item.reload.last_consumed_on).to eq Date.current - 5
    end
  end

  # 「最近編集した品目」などの表示を壊さないよう、キャッシュの書き戻しで updated_at は汚さない
  it "再計算で items.updated_at は変わらない" do
    create(:lot, item: item, initial_quantity: 12)
    item.reload
    updated_at = item.updated_at

    travel_to 1.hour.from_now do
      described_class.call(item)
    end

    expect(item.reload.updated_at).to eq updated_at
  end

  it "渡した item のインスタンスにも新しい値が入る (reload しなくても読める)" do
    create(:lot, item: item, initial_quantity: 12, with_movement: false)
    item.lots.first.stock_movements.create!(item: item, user: user, kind: :purchase,
      quantity: 12, occurred_on: Date.current)

    described_class.call(item)

    expect(item.current_quantity).to eq 12
  end
end
