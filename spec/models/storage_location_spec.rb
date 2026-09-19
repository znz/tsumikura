require "rails_helper"

RSpec.describe StorageLocation, type: :model do
  describe "バリデーション" do
    it "name は必須" do
      storage_location = build(:storage_location, name: "")

      expect(storage_location).not_to be_valid
      expect(storage_location.errors[:name]).to be_present
    end

    it "name は一意" do
      create(:storage_location, name: "洗面所")
      duplicate = build(:storage_location, name: "洗面所")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to be_present
    end

    it "name は 50 文字まで" do
      expect(build(:storage_location, name: "あ" * 50)).to be_valid
      expect(build(:storage_location, name: "あ" * 51)).not_to be_valid
    end

    it "name の前後の空白を落とす (全角スペースも)" do
      expect(create(:storage_location, name: "　洗面所　").name).to eq "洗面所"
    end

    it "全角スペースの有無だけが違う名前は重複として弾く" do
      create(:storage_location, name: "洗面所")

      expect(build(:storage_location, name: "洗面所　")).not_to be_valid
    end
  end

  describe "並び順" do
    it "作成順に position が振られ、.ordered はその順で返す" do
      first = create(:storage_location)
      second = create(:storage_location)

      expect(described_class.ordered.to_a).to eq [ first, second ]
    end

    it "#move! :up は 1 つ上と入れ替える" do
      first = create(:storage_location)
      second = create(:storage_location)

      second.move!(:up)

      expect(described_class.ordered.to_a).to eq [ second, first ]
    end
  end

  describe "削除" do
    it "削除しても品目は消えず、保管場所だけが外れる" do
      storage_location = create(:storage_location)
      item = create(:item, storage_location: storage_location)

      expect { storage_location.destroy }.not_to change { Item.count }
      expect(item.reload.storage_location).to be_nil
    end
  end
end
