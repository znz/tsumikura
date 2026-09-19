require "rails_helper"

RSpec.describe Store, type: :model do
  describe "バリデーション" do
    it "name は必須" do
      store = build(:store, name: "")

      expect(store).not_to be_valid
      expect(store.errors[:name]).to be_present
    end

    it "name は一意" do
      create(:store, name: "スーパーA")
      duplicate = build(:store, name: "スーパーA")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to be_present
    end

    it "name は 50 文字まで" do
      expect(build(:store, name: "あ" * 50)).to be_valid
      expect(build(:store, name: "あ" * 51)).not_to be_valid
    end

    it "name の前後の空白を落とす (全角スペースも)" do
      expect(create(:store, name: "　やおや　").name).to eq "やおや"
    end

    it "全角スペースの有無だけが違う名前は重複として弾く" do
      create(:store, name: "やおや")

      expect(build(:store, name: "やおや　")).not_to be_valid
    end

    it "メモは任意" do
      expect(build(:store, note: nil)).to be_valid
      expect(build(:store, note: "駅前。日曜は混む")).to be_valid
    end
  end

  # マスタの削除は nullify。購入の記録は消さず店舗だけを外す
  # (docs/spec/01-domain-model.md 3 節)
  describe "購入の記録との関連" do
    it "削除しても購入の記録は残り、店舗だけが外れる" do
      store = create(:store)
      lot = create(:lot, store: store)

      expect { store.destroy }.not_to change { Lot.count }
      expect(lot.reload.store_id).to be_nil
    end

    # dependent: :nullify は destroy でしか働かない。DB 側の on_delete: :nullify が
    # 効いていることを、コールバックを通らない delete で確かめる
    it "コールバックを通らない delete でも DB 側で store_id が nil になる" do
      store = create(:store)
      lot = create(:lot, store: store)

      store.delete

      expect(lot.reload.store_id).to be_nil
      expect(Lot.exists?(lot.id)).to be true
    end

    it "削除しても在庫数は変わらない" do
      store = create(:store)
      item = create(:item)
      create(:lot, item: item, store: store, initial_quantity: 12)

      store.destroy

      expect(item.reload.current_quantity).to eq 12
    end

    it "別の店舗の購入の記録は影響を受けない" do
      deleted = create(:store)
      kept = create(:store)
      create(:lot, store: deleted)
      lot = create(:lot, store: kept)

      deleted.destroy

      expect(lot.reload.store_id).to eq kept.id
    end
  end

  # 店舗は position を持たない (docs/spec/01-domain-model.md 2 節) ので名前順に並べる
  describe ".ordered" do
    it "名前順に返す" do
      last = create(:store, name: "やおや")
      first = create(:store, name: "あおぞら")

      expect(described_class.ordered.to_a).to eq [ first, last ]
    end
  end
end
