require "rails_helper"

RSpec.describe Category, type: :model do
  describe "バリデーション" do
    it "name は必須" do
      category = build(:category, name: "")

      expect(category).not_to be_valid
      expect(category.errors[:name]).to be_present
    end

    it "name は一意" do
      create(:category, name: "日用品")
      duplicate = build(:category, name: "日用品")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to be_present
    end

    it "name は 50 文字まで" do
      expect(build(:category, name: "あ" * 50)).to be_valid
      expect(build(:category, name: "あ" * 51)).not_to be_valid
    end

    it "name の前後の空白を落とす (全角スペースも)" do
      expect(create(:category, name: " 日用品 ").name).to eq "日用品"
      expect(create(:category, name: "　食品　").name).to eq "食品"
    end

    # 全角スペースを落とさないと「日用品」と「日用品　」が別名として一意制約をすり抜ける
    it "全角スペースの有無だけが違う名前は重複として弾く" do
      create(:category, name: "日用品")

      expect(build(:category, name: "日用品　")).not_to be_valid
    end
  end

  describe "並び順" do
    it "作成順に position が振られ、.ordered はその順で返す" do
      first = create(:category, name: "あ")
      second = create(:category, name: "い")
      third = create(:category, name: "う")

      expect(described_class.ordered.to_a).to eq [ first, second, third ]
      expect([ first, second, third ].map { _1.reload.position }).to eq [ 1, 2, 3 ]
    end

    it "#move! :up は 1 つ上と入れ替える" do
      first = create(:category)
      second = create(:category)
      third = create(:category)

      expect(second.move!(:up)).to be true

      expect(described_class.ordered.to_a).to eq [ second, first, third ]
    end

    it "#move! :down は 1 つ下と入れ替える" do
      first = create(:category)
      second = create(:category)
      third = create(:category)

      expect(second.move!(:down)).to be true

      expect(described_class.ordered.to_a).to eq [ first, third, second ]
    end

    it "先頭の #move! :up と末尾の #move! :down は何もせず false を返す" do
      first = create(:category)
      second = create(:category)

      expect(first.move!(:up)).to be false
      expect(second.move!(:down)).to be false
      expect(described_class.ordered.to_a).to eq [ first, second ]
    end

    it "未知の方向では何もせず false を返す" do
      first = create(:category)
      second = create(:category)

      expect(second.move!("sideways")).to be false
      expect(described_class.ordered.to_a).to eq [ first, second ]
    end

    it "position が重複していても .ordered と #move! は安定して動く" do
      first = create(:category)
      second = create(:category)
      third = create(:category)
      described_class.update_all(position: 0)

      expect(third.move!(:up)).to be true

      expect(described_class.ordered.to_a).to eq [ first, third, second ]
    end

    it "並べ替えても updated_at は汚さない" do
      create(:category)
      second = create(:category)
      before = second.reload.updated_at

      second.move!(:up)

      expect(second.reload.updated_at).to eq before
    end
  end

  describe "削除" do
    it "削除しても品目は消えず、カテゴリだけが外れる" do
      category = create(:category)
      item = create(:item, category: category)

      expect { category.destroy }.not_to change { Item.count }
      expect(item.reload.category).to be_nil
    end

    it "#items には紐づく品目だけが入る (削除前の件数表示に使う)" do
      category = create(:category)
      create(:item, category: category)
      create(:item, category: category)
      create(:item)

      expect(category.items.count).to eq 2
    end
  end
end
