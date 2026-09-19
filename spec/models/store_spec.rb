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

  # 店舗は position を持たない (docs/spec/01-domain-model.md 2 節) ので名前順に並べる
  describe ".ordered" do
    it "名前順に返す" do
      last = create(:store, name: "やおや")
      first = create(:store, name: "あおぞら")

      expect(described_class.ordered.to_a).to eq [ first, last ]
    end
  end
end
