require "rails_helper"

RSpec.describe Stock::WriteStockTakeEntries, type: :model do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:kitchen) { create(:storage_location, name: "台所") }
  let(:item) { create(:item, name: "ラップ", storage_location: kitchen) }
  let(:stock_take) { create(:stock_take, storage_location: kitchen) }

  def write(counts, target: stock_take)
    described_class.call(target, counts: counts)
  end

  def total(item, value, was: nil)
    { item.id.to_s => { "total" => value, "was" => was } }
  end

  def entry_for(target_item, lot = nil)
    stock_take.stock_take_entries.find_by(item_id: target_item.id, lot_id: lot&.id)
  end

  describe "実数の書き込み" do
    before { create(:lot, item: item, initial_quantity: 10) }

    it "入力された品目のぶんだけ明細を作る (在庫は動かさない)" do
      expect { write(total(item, "7")) }.to change { StockTakeEntry.count }.by(1)

      expect(entry_for(item)).to have_attributes(expected_quantity: 10, counted_quantity: 7,
        difference: -3)
      expect(StockMovement.kind_adjustment.count).to eq 0
      expect(item.reload.current_quantity).to eq 10
    end

    it "未入力の品目には明細を作らない" do
      expect { write(total(item, "")) }.not_to change { StockTakeEntry.count }
    end

    it "入れた実数を空にすると明細が消える" do
      write(total(item, "7"))

      expect { write(total(item, "", was: "7")) }.to change { StockTakeEntry.count }.by(-1)
    end

    it "数字でない実数・マイナス・上限超えは何も書かずに false を返す" do
      expect(write(total(item, "abc"))).to be false
      expect(write(total(item, "-1"))).to be false
      expect(write(total(item, (Item::MAX_QUANTITY + 1).to_s))).to be false
      expect(StockTakeEntry.count).to eq 0
    end

    it "対象外 (他の保管場所・アーカイブ済み) の品目は無視する" do
      elsewhere = create(:item, storage_location: create(:storage_location))
      archived = create(:item, :archived, storage_location: kitchen)

      expect { write(total(elsewhere, "3").merge(total(archived, "3"))) }
        .not_to change { StockTakeEntry.count }
    end
  end

  # フォームは全品目を送るので、そのまま書くと別のタブ・別の人が先に入れた実数を
  # 空欄で上書き (削除) してしまう
  describe "書き換えた欄だけを反映する" do
    let(:other) { create(:item, name: "アルミホイル", storage_location: kitchen) }

    before do
      create(:lot, item: item, initial_quantity: 10)
      create(:lot, item: other, initial_quantity: 4)
    end

    it "古い画面を送り直しても、あとから入った実数は消えない" do
      # A さんがラップを数えて保存
      write(total(item, "7"))
      # B さんは両方とも空の画面を開いたまま、アルミホイルだけ入れて保存
      stale = total(item, "", was: "").merge(total(other, "2", was: ""))

      write(stale)

      expect(entry_for(item).counted_quantity).to eq 7
      expect(entry_for(other).counted_quantity).to eq 2
    end

    it "値を消したとき (元の値あり → 空) だけ明細が消える" do
      write(total(item, "7"))

      write(total(item, "", was: "7"))

      expect(entry_for(item)).to be_nil
    end

    it "同じ欄を 2 人が別の値にしたら後勝ち" do
      write(total(item, "7"))
      write(total(item, "5", was: ""))

      expect(entry_for(item).counted_quantity).to eq 5
    end

    it "値が同じなら明細を作り直さない (updated_at を汚さない)" do
      write(total(item, "7"))
      entry = entry_for(item)

      expect { write(total(item, "7", was: "7")) }.not_to change { entry.reload.updated_at }
    end
  end

  describe "ロット別の入力" do
    let(:item) { create(:item, :tracks_expiry, name: "たまご", storage_location: kitchen) }
    let!(:near) { create(:lot, item: item, initial_quantity: 6, expires_on: Date.current + 1) }
    let!(:far) { create(:lot, item: item, initial_quantity: 6, expires_on: Date.current + 30) }

    def lots(values, was: {})
      { item.id.to_s => { "lots" => values, "lots_was" => was } }
    end

    it "ロットごとに明細を作る" do
      write(lots({ near.id.to_s => "4" }))

      expect(entry_for(item, near)).to have_attributes(expected_quantity: 6, counted_quantity: 4)
      expect(entry_for(item, far)).to be_nil
    end

    # より細かいほうを採る (二重に数えない)
    it "ロット別に入れると合計の明細は落とす" do
      write(total(item, "12"))
      expect(entry_for(item)).to be_present

      write(lots({ near.id.to_s => "4" }))

      expect(entry_for(item)).to be_nil
      expect(entry_for(item, near).counted_quantity).to eq 4
    end

    it "ロット別を全部空にすれば、そのあと合計で数え直せる" do
      write(lots({ near.id.to_s => "4" }))
      write(lots({ near.id.to_s => "" }, was: { near.id.to_s => "4" })
        .deep_merge(total(item, "9")))

      expect(entry_for(item, near)).to be_nil
      expect(entry_for(item).counted_quantity).to eq 9
    end

    it "他の品目のロット id は無視する" do
      other_lot = create(:lot, item: create(:item), initial_quantity: 5)

      expect { write(lots({ other_lot.id.to_s => "2" })) }.not_to change { StockTakeEntry.count }
    end

    it "画面に無かったロットの欄は送られないので触らない" do
      write(lots({ near.id.to_s => "4" }))

      write(lots({ far.id.to_s => "5" }))

      expect(entry_for(item, near).counted_quantity).to eq 4
      expect(entry_for(item, far).counted_quantity).to eq 5
    end
  end

  # 1 台が「確定」、別のタブが「途中保存」を同時に押すと、movement は古い差分のままで
  # 明細だけが変わり「差分 ≠ movements の合計」が残ってしまう
  describe "確定との競合" do
    before { create(:lot, item: item, initial_quantity: 10) }

    it "確定前に読んだ古いインスタンスでは書き込めない (404 と同じ扱い)" do
      stale = stock_take
      write(total(item, "7"))
      Stock::FinalizeStockTake.call(StockTake.find(stock_take.id), user: create(:user))

      expect { write(total(item, "3", was: "7"), target: stale) }
        .to raise_error(ActiveRecord::RecordNotFound)

      expect(entry_for(item).counted_quantity).to eq 7
    end

    it "ヘッダを行ロックしてから書く" do
      # let は遅延評価なので、書き込みを始める前にすべて作っておく
      item
      stock_take

      statements = recorded_sql { write(total(item, "7")) }

      expect(first_lock_index(statements)).not_to be_nil
      expect(first_lock_index(statements)).to be < first_write_index(statements)
    end
  end
end
