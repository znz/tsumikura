require "rails_helper"

RSpec.describe UsageRecord, type: :model do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:item) { create(:item, name: "単 3 電池", unit: "本") }

  describe "バリデーション" do
    it "quantity は 1 以上" do
      expect(build(:usage_record, item: item, quantity: 0)).not_to be_valid
      expect(build(:usage_record, item: item, quantity: -1)).not_to be_valid
      expect(build(:usage_record, item: item, quantity: 1)).to be_valid
    end

    it "4 バイト整数をはみ出す quantity でも例外にならず検証エラーになる" do
      record = build(:usage_record, item: item, quantity: 99_999_999_999)

      expect(record).not_to be_valid
      expect(record.errors[:quantity]).to be_present
    end

    it "used_on は必須" do
      expect(build(:usage_record, item: item, used_on: nil)).not_to be_valid
    end

    # 「リモコンは 2 本」を JS 無しでも効かせる (docs/spec/03-screens.md 画面 4)
    it "quantity が空なら 1 で補う" do
      record = build(:usage_record, item: item, quantity: nil)

      expect(record).to be_valid
      expect(record.quantity).to eq 1
    end

    it "quantity が空で用途を選んでいれば、その用途の既定数量で補う" do
      purpose = create(:item_purpose, item: item, default_quantity: 2)
      record = build(:usage_record, item: item, quantity: nil, item_purpose: purpose)

      expect(record).to be_valid
      expect(record.quantity).to eq 2
    end

    it "quantity が 0 なら補わずに検証エラーにする" do
      expect(build(:usage_record, item: item, quantity: 0)).not_to be_valid
    end

    # 消費イベントが必ず今日以前にあることを予測が前提にしている
    it "未来の日付は保存できない (今日は可、明日は不可)" do
      travel_to Time.current.change(hour: 0, min: 10) do
        expect(build(:usage_record, item: item, used_on: Date.current)).to be_valid
        expect(build(:usage_record, item: item, used_on: Date.current + 1)).not_to be_valid
      end
    end
  end

  describe "用途" do
    it "用途なしで保存できる" do
      expect(build(:usage_record, item: item, item_purpose: nil)).to be_valid
    end

    it "同じ品目の用途は指定できる" do
      purpose = create(:item_purpose, item: item)

      expect(build(:usage_record, item: item, item_purpose: purpose)).to be_valid
    end

    it "他の品目の用途は指定できない" do
      purpose = create(:item_purpose, item: create(:item))
      record = build(:usage_record, item: item, item_purpose: purpose)

      expect(record).not_to be_valid
      expect(record.errors[:item_purpose]).to be_present
    end

    # フォームを開いている間に用途が削除されると、そのままでは外部キー違反 (500) になる
    it "削除済みの用途 id では保存できない" do
      purpose = create(:item_purpose, item: item)
      purpose_id = purpose.id
      purpose.destroy

      record = build(:usage_record, item: item, item_purpose_id: purpose_id)

      expect(record).not_to be_valid
      expect(record.errors[:item_purpose]).to be_present
    end

    it "UUID の形でない用途 id (0) でも 500 にせず検証エラーになる" do
      expect(build(:usage_record, item: item, item_purpose_id: 0)).not_to be_valid
    end

    # 壊れた値とは経路が違う (こちらは cast が通って関連が nil になる)
    it "形は正しいが存在しない用途の UUID でも検証エラーになる" do
      record = build(:usage_record, item: item, item_purpose_id: nonexistent_uuid)

      expect(record).not_to be_valid
      expect(record.errors[:item_purpose]).to be_present
    end

    # 引けない id のまま関連をたどらないことを固定する (500 にしない)
    it "UUID の形でない用途 id でも 500 にせず検証エラーになる" do
      record = build(:usage_record, item: item, item_purpose_id: "99999999999999999999")

      expect(record).not_to be_valid
      expect(record.errors[:item_purpose]).to be_present
    end
  end

  # 引き当て先のロットの手動指定 (DB には持たない)
  describe "#selected_lot_id" do
    it "指定が無ければ nil (FEFO の自動引き当て)" do
      record = build(:usage_record, item: item)

      expect(record.selected_lot_id).to be_nil
      expect(record).to be_valid
    end

    it "同じ品目のロットなら id を返す" do
      lot = create(:lot, item: item, initial_quantity: 3)
      record = build(:usage_record, item: item, lot_id: lot.id.to_s)

      expect(record.selected_lot_id).to eq lot.id
      expect(record).to be_valid
    end

    it "他の品目のロットは指定できない" do
      lot = create(:lot, item: create(:item), initial_quantity: 3)
      record = build(:usage_record, item: item, lot_id: lot.id)

      expect(record).not_to be_valid
      expect(record.errors[:lot_id]).to be_present
      expect(record.selected_lot_id).to be_nil
    end

    it "数字でない lot_id でも 500 にせず検証エラーになる" do
      expect(build(:usage_record, item: item, lot_id: "きのうの")).not_to be_valid
    end

    it "UUID の形でない lot_id でも 500 にせず検証エラーになる" do
      expect(build(:usage_record, item: item, lot_id: "99999999999999999999")).not_to be_valid
      expect(build(:usage_record, item: item, lot_id: Base58Uuid.encode(SecureRandom.uuid))).not_to be_valid
    end

    it "存在しない UUID の lot_id も検証エラーになる" do
      expect(build(:usage_record, item: item, lot_id: nonexistent_uuid)).not_to be_valid
    end

    # PostgreSQL の uuid 型は大文字小文字を区別しないので、大文字を通すと
    # exists? は true なのに Stock::Allocator の `lot.id == preferred_lot_id` が外れ、
    # 「指定したロットは使い切り」扱いで**黙って別のロットから引かれて**しまう。
    # POST の本文の UUID はアプリが描いた小文字だけなので、大文字は検証エラーでよい
    it "大文字の UUID の lot_id は検証エラーになる (黙って別ロットに倒さない)" do
      lot = create(:lot, item: item, initial_quantity: 3)
      record = build(:usage_record, item: item, lot_id: lot.id.upcase)

      expect(record.selected_lot_id).to be_nil
      expect(record).not_to be_valid
      expect(record.errors[:lot_id]).to be_present
    end
  end

  describe "関連" do
    it "削除すると紐づく movement も消える" do
      create(:lot, item: item, initial_quantity: 5)
      record = create(:usage_record, item: item, quantity: 2)

      expect { record.destroy }.to change { StockMovement.count }.by(-1)
    end

    it "品目を削除すると使用記録も消える" do
      create(:usage_record, item: item)

      expect { item.destroy }.to change { described_class.count }.by(-1)
    end
  end

  describe "DB の制約" do
    # 例外でテスト用トランザクションが壊れないよう SAVEPOINT の中で試す
    it "quantity を 0 にする UPDATE は check 制約で弾かれる" do
      record = create(:usage_record, item: item, quantity: 2)

      expect {
        described_class.transaction(requires_new: true) { record.update_column(:quantity, 0) }
      }.to raise_error(ActiveRecord::StatementInvalid)

      expect(record.reload.quantity).to eq 2
    end

    # 記録者が消えると「誰が使ったか」が失われるので DB 側でも止める
    it "記録者のユーザーは物理削除できない" do
      user = create(:user)
      create(:usage_record, item: item, user: user)

      expect {
        described_class.transaction(requires_new: true) { user.delete }
      }.to raise_error(ActiveRecord::StatementInvalid, /RestrictViolation/)
    end

    # Phase 7 で列だけ作っておいた stock_movements.usage_record_id の外部キー。
    # movement を先に消さずに使用記録だけを消すと、台帳が宙に浮いてキャッシュがずれる
    it "movement が残ったまま使用記録を delete すると外部キーで弾かれる" do
      create(:lot, item: item, initial_quantity: 5)
      record = create(:usage_record, item: item, quantity: 2)

      expect {
        described_class.transaction(requires_new: true) { record.delete }
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    # 非正規化した item_id が使用記録とずれた movement は、品目単位の再計算から
    # 黙って落ちる (別の品目のキャッシュが古いまま残る)。複合外部キーで DB 側から止める
    it "使用記録と違う品目を指す movement の UPDATE は複合外部キーで弾かれる" do
      create(:lot, item: item, initial_quantity: 5)
      record = create(:usage_record, item: item, quantity: 2)
      other = create(:item)

      expect {
        described_class.transaction(requires_new: true) {
          record.stock_movements.sole.update_column(:item_id, other.id)
        }
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "movement が残ったまま使用記録の品目を付け替える UPDATE も弾かれる" do
      create(:lot, item: item, initial_quantity: 5)
      record = create(:usage_record, item: item, quantity: 2)
      other = create(:item)

      expect {
        described_class.transaction(requires_new: true) { record.update_column(:item_id, other.id) }
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    # 用途も (item_purpose_id, item_id) の複合外部キーで品目をそろえる
    it "他の品目の用途を指す UPDATE は複合外部キーで弾かれる" do
      record = create(:usage_record, item: item)
      other_purpose = create(:item_purpose, item: create(:item))

      expect {
        described_class.transaction(requires_new: true) {
          record.update_column(:item_purpose_id, other_purpose.id)
        }
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end
end
