require "rails_helper"

RSpec.describe User, type: :model do
  describe "バリデーション" do
    it "表示名・メールアドレス・パスワードが揃っていれば保存できる" do
      user = build(:user)

      expect(user).to be_valid
    end

    it "表示名が無ければ保存できない" do
      user = build(:user, name: "")

      expect(user).not_to be_valid
      expect(user.errors[:name]).to be_present
    end

    it "メールアドレスが無ければ保存できない" do
      user = build(:user, email_address: "")

      expect(user).not_to be_valid
      expect(user.errors[:email_address]).to be_present
    end

    it "メールアドレスの形式が不正なら保存できない" do
      user = build(:user, email_address: "かぞく")

      expect(user).not_to be_valid
      expect(user.errors[:email_address]).to be_present
    end

    it "メールアドレスは大文字小文字を無視して一意になる" do
      create(:user, email_address: "family@example.com")
      user = build(:user, email_address: "Family@Example.com")

      expect(user).not_to be_valid
      expect(user.errors[:email_address]).to be_present
    end

    it "メールアドレスは前後の空白を落として小文字で保存される" do
      user = create(:user, email_address: "  Family@Example.com  ")

      expect(user.email_address).to eq "family@example.com"
    end

    it "パスワードが最小長より短ければ保存できない" do
      user = build(:user, password: "a" * (User::MINIMUM_PASSWORD_LENGTH - 1))

      expect(user).not_to be_valid
      expect(user.errors[:password]).to be_present
    end

    it "パスワードが最小長ちょうどなら保存できる" do
      user = build(:user, password: "a" * User::MINIMUM_PASSWORD_LENGTH)

      expect(user).to be_valid
    end

    it "パスワードを変更しない更新では最小長を問われない" do
      user = create(:user)

      expect(user.update(name: "おかあさん")).to be true
    end
  end

  describe "#role" do
    it "既定は member" do
      expect(build(:user)).to be_member
    end

    it "admin? は role が admin のとき true" do
      expect(build(:user, :admin)).to be_admin
    end

    it "admin? は role が member のとき false" do
      expect(build(:user)).not_to be_admin
    end
  end

  describe "無効化" do
    it "deactivated_at が入っていれば deactivated? は true" do
      expect(build(:user, :deactivated)).to be_deactivated
    end

    it "deactivated_at が nil なら deactivated? は false" do
      expect(build(:user)).not_to be_deactivated
    end

    it "User.active は無効化されていないユーザーだけを返す" do
      active = create(:user)
      create(:user, :deactivated)

      expect(User.active).to contain_exactly(active)
    end
  end

  describe "最後の管理者の保護" do
    it "有効な管理者が 1 人だけのとき、その管理者は降格できない" do
      admin = create(:user, :admin)
      create(:user)

      expect(admin.update(role: :member)).to be false
      expect(admin.errors[:role]).to be_present
    end

    it "有効な管理者が 1 人だけのとき、その管理者は無効化できない" do
      admin = create(:user, :admin)
      create(:user)

      expect(admin.update(deactivated_at: Time.current)).to be false
      expect(admin.errors[:deactivated_at]).to be_present
    end

    it "有効な管理者が 2 人いれば降格できる" do
      admin = create(:user, :admin)
      create(:user, :admin)

      expect(admin.update(role: :member)).to be true
    end

    it "有効な管理者が 2 人いれば無効化できる" do
      admin = create(:user, :admin)
      create(:user, :admin)

      expect(admin.update(deactivated_at: Time.current)).to be true
    end

    it "無効化済みの管理者は「有効な管理者」に数えない" do
      admin = create(:user, :admin)
      create(:user, :admin, :deactivated)

      expect(admin.update(role: :member)).to be false
    end

    it "最後の管理者でも表示名は変更できる" do
      admin = create(:user, :admin)

      expect(admin.update(name: "おとうさん")).to be true
    end

    it "無効化済みの管理者は再有効化できる" do
      create(:user, :admin)
      deactivated_admin = create(:user, :admin, :deactivated)

      expect(deactivated_admin.update(deactivated_at: nil)).to be true
    end

    it "無効化済みの管理者は降格できる (有効な管理者が減らないため)" do
      create(:user, :admin)
      deactivated_admin = create(:user, :admin, :deactivated)

      expect(deactivated_admin.update(role: :member)).to be true
    end

    it "一般ユーザーは管理者が 1 人でも無効化できる" do
      create(:user, :admin)
      member = create(:user)

      expect(member.update(deactivated_at: Time.current)).to be true
    end
  end

  describe ".generate_password" do
    it "読み間違えやすい文字を文字種から除いている" do
      expect(User::GENERATED_PASSWORD_CHARS & %w[ 0 1 O o I i l Q ]).to be_empty
    end

    it "書き写しやすいよう 4 文字 4 群をハイフンで繋いだ形式になる" do
      expect(User.generate_password).to match(/\A(?:[a-zA-Z2-9]{4}-){3}[a-zA-Z2-9]{4}\z/)
    end

    it "推測されない長さ (ハイフンを除いて 16 文字) がある" do
      expect(User.generate_password.delete("-").length).to eq 16
    end

    it "呼ぶたびに異なるパスワードを返す" do
      expect(User.generate_password).not_to eq User.generate_password
    end

    it "生成したパスワードはそのまま保存できる" do
      user = build(:user, password: User.generate_password)

      expect(user).to be_valid
    end
  end
end
