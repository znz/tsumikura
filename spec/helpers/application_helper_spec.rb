require "rails_helper"

RSpec.describe ApplicationHelper, type: :helper do
  describe "#name_with_san" do
    it "表示名に「さん」を付ける" do
      expect(helper.name_with_san("はなこ")).to eq "はなこさん"
    end

    # 家族の表示名は「おかあさん」のように敬称込みで登録されることが多い
    it "すでに敬称で終わっている表示名には重ねない" do
      %w[おかあさん たろうくん はなちゃん おきゃくさま 山田様].each do |name|
        expect(helper.name_with_san(name)).to eq name
      end
    end

    it "前後の空白は見ない" do
      expect(helper.name_with_san(" おかあさん ")).to eq "おかあさん"
    end
  end
end
