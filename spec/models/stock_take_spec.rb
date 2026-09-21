require "rails_helper"

RSpec.describe StockTake, type: :model do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  describe "バリデーション" do
    it "棚卸日は必須" do
      expect(build(:stock_take, counted_on: nil)).not_to be_valid
    end

    # 消費イベントが必ず今日以前にあることを予測が前提にしている
    it "未来の日付は指定できない (今日は可、明日は不可)" do
      expect(build(:stock_take, counted_on: Date.current)).to be_valid
      expect(build(:stock_take, counted_on: Date.current + 1)).not_to be_valid
    end

    # フォームを開いている間に保管場所が削除されると、そのままでは外部キー違反 (500) になる。
    # uuid 列は UUID の形でない値を nil にキャストするので、経路が 2 つに分かれる:
    # (1) 壊れた値 = *_before_type_cast が present なのに id が nil
    # (2) 形は正しいが存在しない UUID = 関連が nil
    it "壊れた保管場所 id (0 / -1) では保存できない" do
      expect(build(:stock_take, storage_location_id: 0)).not_to be_valid
      expect(build(:stock_take, storage_location_id: -1)).not_to be_valid
    end

    it "形は正しいが存在しない保管場所の UUID でも保存できない" do
      stock_take = build(:stock_take, storage_location_id: nonexistent_uuid)

      expect(stock_take).not_to be_valid
      expect(stock_take.errors[:storage_location]).to be_present
    end

    it "保管場所は任意 (nil は全体の棚卸)" do
      expect(build(:stock_take, storage_location: nil)).to be_valid
    end
  end

  describe "スコープ" do
    let!(:draft) { create(:stock_take) }
    let!(:finalized) { create(:stock_take, :finalized) }

    it "drafts は下書きだけ、finalized は確定済みだけを返す" do
      expect(described_class.drafts).to contain_exactly draft
      expect(described_class.finalized).to contain_exactly finalized
    end

    it "recent_first は棚卸日の新しい順 (同じ日なら後から作ったもの)" do
      older = create(:stock_take, counted_on: Date.current - 3)
      newer = create(:stock_take, counted_on: Date.current)

      expect(described_class.recent_first.first).to eq newer
      expect(described_class.recent_first.to_a.last).to eq older
    end
  end

  describe "#target_items" do
    let(:kitchen) { create(:storage_location, name: "台所") }
    let(:bathroom) { create(:storage_location, name: "洗面所") }

    it "保管場所を指定した棚卸には、その場所の品目だけが並ぶ" do
      here = create(:item, name: "ラップ", storage_location: kitchen)
      create(:item, name: "歯ブラシ", storage_location: bathroom)
      create(:item, name: "場所なし")

      expect(create(:stock_take, storage_location: kitchen).target_items).to contain_exactly here
    end

    it "アーカイブ済みの品目は並ばない" do
      create(:item, :archived, name: "むかしの品目", storage_location: kitchen)

      expect(create(:stock_take, storage_location: kitchen).target_items).to be_empty
    end

    it "保管場所なしの棚卸には、有効な品目がすべて並ぶ" do
      here = create(:item, storage_location: kitchen)
      there = create(:item, storage_location: nil)
      create(:item, :archived)

      expect(create(:stock_take, storage_location: nil).target_items).to contain_exactly here, there
    end
  end

  describe "差分のサマリ" do
    let(:stock_take) { create(:stock_take) }

    before do
      create(:stock_take_entry, stock_take: stock_take, expected_quantity: 5, counted_quantity: 7)
      create(:stock_take_entry, stock_take: stock_take, expected_quantity: 5, counted_quantity: 2)
      create(:stock_take_entry, stock_take: stock_take, expected_quantity: 5, counted_quantity: 5)
      create(:stock_take_entry, stock_take: stock_take, expected_quantity: 5, counted_quantity: nil)
    end

    it "増えた明細 / 減った明細の数を返す (差分 0 と未入力は数えない)" do
      expect(stock_take.increased_entries.count).to eq 1
      expect(stock_take.decreased_entries.count).to eq 1
      expect(stock_take.counted_entries.count).to eq 3
    end
  end

  # 確定済みは削除しない (docs/spec/01-domain-model.md 3 節)。
  # 調整 movement の履歴が残るため
  describe "削除" do
    it "下書きは削除でき、明細も一緒に消える" do
      stock_take = create(:stock_take)
      create(:stock_take_entry, stock_take: stock_take)

      expect { stock_take.destroy }.to change { described_class.count }.by(-1)
        .and change { StockTakeEntry.count }.by(-1)
    end

    it "確定済みは削除できない" do
      stock_take = create(:stock_take, :finalized)

      expect { stock_take.destroy }.not_to change { described_class.count }
      expect(stock_take.errors.full_messages.join).to include "確定済み"
    end
  end
end
