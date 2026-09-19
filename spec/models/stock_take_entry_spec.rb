require "rails_helper"

RSpec.describe StockTakeEntry, type: :model do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:item) { create(:item) }
  let(:stock_take) { create(:stock_take) }

  describe "difference は counted - expected から入れる (フォームからは受け取らない)" do
    it "実数が記録在庫より少なければマイナス" do
      entry = create(:stock_take_entry, item: item, expected_quantity: 10, counted_quantity: 7)

      expect(entry.difference).to eq(-3)
    end

    it "実数が記録在庫より多ければプラス" do
      entry = create(:stock_take_entry, item: item, expected_quantity: 10, counted_quantity: 12)

      expect(entry.difference).to eq 2
    end

    it "未入力 (counted_quantity が nil) なら difference も nil" do
      entry = create(:stock_take_entry, item: item, expected_quantity: 10, counted_quantity: nil)

      expect(entry.difference).to be_nil
      expect(entry).not_to be_counted
    end

    it "difference を直接渡しても、counted - expected で上書きされる" do
      entry = create(:stock_take_entry, item: item, expected_quantity: 10, counted_quantity: 7,
        difference: 999)

      expect(entry.difference).to eq(-3)
    end
  end

  describe "バリデーション" do
    it "実数は 0 以上 (マイナスは入力の誤り)" do
      expect(build(:stock_take_entry, counted_quantity: 0)).to be_valid
      expect(build(:stock_take_entry, counted_quantity: -1)).not_to be_valid
    end

    # 上限が無いと 4 バイト整数をはみ出した入力が RangeError になり 422 ではなく 500 になる
    it "実数には上限があり、4 バイト整数をはみ出しても検証エラーになる" do
      entry = build(:stock_take_entry, counted_quantity: 3_000_000_000)

      expect(entry).not_to be_valid
      expect(entry.errors[:counted_quantity]).to be_present
    end

    it "記録在庫は必須で 0 以上" do
      expect(build(:stock_take_entry, expected_quantity: nil)).not_to be_valid
      expect(build(:stock_take_entry, expected_quantity: -1)).not_to be_valid
    end

    it "ロットは同じ品目のものでなければならない" do
      other_lot = create(:lot, item: create(:item))

      entry = build(:stock_take_entry, item: item, lot: other_lot)

      expect(entry).not_to be_valid
      expect(entry.errors[:lot]).to be_present
    end

    it "同じ品目のロットなら指定できる" do
      lot = create(:lot, item: item)

      expect(build(:stock_take_entry, item: item, lot: lot)).to be_valid
    end

    # 8 バイト整数をはみ出す id を where に渡すと PG が範囲エラーを返して 500 になる
    it "8 バイト整数をはみ出すロット id でも例外にならず検証エラーになる" do
      entry = build(:stock_take_entry, item: item, lot_id: 2**63)

      expect(entry).not_to be_valid
      expect(entry.errors[:lot]).to be_present
    end
  end

  describe "スコープ" do
    let!(:increased) { create(:stock_take_entry, stock_take: stock_take, expected_quantity: 1, counted_quantity: 3) }
    let!(:decreased) { create(:stock_take_entry, stock_take: stock_take, expected_quantity: 3, counted_quantity: 1) }
    let!(:same) { create(:stock_take_entry, stock_take: stock_take, expected_quantity: 3, counted_quantity: 3) }
    let!(:blank) { create(:stock_take_entry, stock_take: stock_take, counted_quantity: nil) }

    it "counted は実数を入力した明細だけ" do
      expect(described_class.counted).to contain_exactly increased, decreased, same
    end

    it "increased / decreased は差分の符号で分かれる" do
      expect(described_class.increased).to contain_exactly increased
      expect(described_class.decreased).to contain_exactly decreased
    end
  end

  # 例外でテスト用トランザクションが壊れないよう SAVEPOINT の中で試す
  describe "DB の制約" do
    it "実数を負にする UPDATE は check 制約で弾かれる" do
      entry = create(:stock_take_entry, counted_quantity: 1)

      expect {
        described_class.transaction(requires_new: true) { entry.update_column(:counted_quantity, -1) }
      }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "difference が counted - expected と食い違う UPDATE は check 制約で弾かれる" do
      entry = create(:stock_take_entry, expected_quantity: 5, counted_quantity: 3)

      expect {
        described_class.transaction(requires_new: true) { entry.update_column(:difference, 0) }
      }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "未入力なのに difference が入っている行は作れない" do
      entry = create(:stock_take_entry, counted_quantity: nil)

      expect {
        described_class.transaction(requires_new: true) { entry.update_column(:difference, 1) }
      }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "同じ棚卸・同じ品目の合計行は 1 行しか作れない" do
      create(:stock_take_entry, stock_take: stock_take, item: item, lot: nil)

      expect {
        described_class.transaction(requires_new: true) do
          described_class.insert_all!([ {
            stock_take_id: stock_take.id, item_id: item.id, expected_quantity: 0,
            created_at: Time.current, updated_at: Time.current
          } ])
        end
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "同じ棚卸・同じ品目・同じロットの明細は 1 行しか作れない" do
      lot = create(:lot, item: item)
      create(:stock_take_entry, stock_take: stock_take, item: item, lot: lot)

      expect {
        described_class.transaction(requires_new: true) do
          described_class.insert_all!([ {
            stock_take_id: stock_take.id, item_id: item.id, lot_id: lot.id, expected_quantity: 0,
            created_at: Time.current, updated_at: Time.current
          } ])
        end
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "合計行とロット別の行は同じ品目でも共存できる (DB では止めない)" do
      lot = create(:lot, item: item)
      create(:stock_take_entry, stock_take: stock_take, item: item, lot: nil)

      expect {
        create(:stock_take_entry, stock_take: stock_take, item: item, lot: lot)
      }.to change { described_class.count }.by(1)
    end

    it "明細と違う品目を指す在庫の記録は複合外部キーで弾かれる" do
      entry = create(:stock_take_entry, item: item, counted_quantity: 1)
      other_lot = create(:lot, item: create(:item))

      expect {
        described_class.transaction(requires_new: true) do
          StockMovement.insert_all!([ {
            item_id: other_lot.item_id, lot_id: other_lot.id, kind: StockMovement.kinds[:adjustment],
            quantity: -1, occurred_on: Date.current, stock_take_entry_id: entry.id,
            user_id: other_lot.user_id, created_at: Time.current, updated_at: Time.current
          } ])
        end
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  # 確定と「途中保存」が同時に走ると、movement は古い差分のままで明細だけが変わり、
  # 「差分 ≠ movements の合計」が残ってしまう。最後の防壁としてモデルでも止める
  describe "確定済みの棚卸の明細" do
    let(:finalized) do
      create(:stock_take).tap do |take|
        create(:stock_take_entry, stock_take: take, item: item, counted_quantity: 1)
        take.update_column(:finalized_at, Time.current)
      end
    end

    it "書き換えられない" do
      entry = finalized.stock_take_entries.sole

      expect { entry.update!(counted_quantity: 2) }.to raise_error(described_class::Finalized)
      expect(entry.reload.counted_quantity).to eq 1
    end

    it "足せない" do
      expect {
        create(:stock_take_entry, stock_take: finalized, item: create(:item), counted_quantity: 1)
      }.to raise_error(described_class::Finalized)
    end

    it "消せない" do
      entry = finalized.stock_take_entries.sole

      expect { entry.destroy }.to raise_error(described_class::Finalized)
      expect(described_class.exists?(entry.id)).to be true
    end

    # 品目ごと消すときは明細も一緒に消える (履歴が半端に残らないようにする)
    it "品目ごと消すときは止めない" do
      finalized

      expect { item.destroy }.to change { described_class.count }.by(-1)
    end

    # 確定 (Stock::FinalizeStockTake) は明細を直してから最後に finalized_at を入れるので、
    # 確定の処理自体はこのガードに引っかからない
    it "確定の処理自体は通る" do
      create(:lot, item: item, initial_quantity: 10)
      stock_take = create(:stock_take)
      entry = create(:stock_take_entry, stock_take: stock_take, item: item,
        expected_quantity: 10, counted_quantity: 7)

      expect { Stock::FinalizeStockTake.call(stock_take, user: create(:user)) }.not_to raise_error
      expect(entry.reload.difference).to eq(-3)
    end
  end

  # 数えてから確定までに使用・購入があると、確定は「今の記録在庫」との差を取る。
  # 確認画面はこの値を見せる (確認した数字と適用される数字を食い違わせない)
  describe "確定で使われる値" do
    it "#current_expected_quantity は品目の今の在庫数" do
      create(:lot, item: item, initial_quantity: 10)
      entry = create(:stock_take_entry, item: item, expected_quantity: 10, counted_quantity: 8)

      Stock::RecordUsage.call(item: item, user: create(:user),
        attributes: { quantity: 1, used_on: Date.current })

      expect(entry.reload.current_expected_quantity).to eq 9
      expect(entry.current_difference).to eq(-1)
      expect(entry.difference).to eq(-2)
      expect(entry).to be_stock_moved_since_counted
    end

    it "ロット別の明細はそのロットの今の残数を見る" do
      lot = create(:lot, item: item, initial_quantity: 6)
      entry = create(:stock_take_entry, item: item, lot: lot, expected_quantity: 6, counted_quantity: 4)

      Stock::RecordUsage.call(item: item, user: create(:user),
        attributes: { quantity: 2, used_on: Date.current, lot_id: lot.id })

      expect(entry.reload.current_expected_quantity).to eq 4
      expect(entry.current_difference).to eq 0
    end

    it "在庫が動いていなければ stock_moved_since_counted? は false" do
      create(:lot, item: item, initial_quantity: 10)
      entry = create(:stock_take_entry, item: item, expected_quantity: 10, counted_quantity: 8)

      expect(entry).not_to be_stock_moved_since_counted
    end

    it "未入力の明細は current_difference も nil" do
      entry = create(:stock_take_entry, item: item, counted_quantity: nil)

      expect(entry.current_difference).to be_nil
      expect(entry).not_to be_stock_moved_since_counted
    end
  end

  # 打ち間違い (12 を 1 と入れるなど) は消費として予測に残り続ける
  describe "#large_decrease?" do
    let(:entry) { build(:stock_take_entry, item: item) }

    it "記録在庫の半分以上が減るなら true" do
      expect(entry.large_decrease?(-5, 10)).to be true
      expect(entry.large_decrease?(-4, 10)).to be false
    end

    it "1 個の減りは大きいとみなさない (日常の誤差)" do
      expect(entry.large_decrease?(-1, 1)).to be false
      expect(entry.large_decrease?(-2, 2)).to be true
    end

    it "増えた差分と未入力は false" do
      expect(entry.large_decrease?(3, 10)).to be false
      expect(entry.large_decrease?(nil, 10)).to be false
    end
  end
end
