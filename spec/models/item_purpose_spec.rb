require "rails_helper"

RSpec.describe ItemPurpose, type: :model do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:item) { create(:item, name: "単 3 電池", unit: "本", tracks_purposes: true) }

  describe "バリデーション" do
    it "name は必須" do
      purpose = build(:item_purpose, item: item, name: "")

      expect(purpose).not_to be_valid
      expect(purpose.errors[:name]).to be_present
    end

    it "name は品目の中で一意 (別の品目なら同じ名前を使える)" do
      create(:item_purpose, item: item, name: "リモコン")

      expect(build(:item_purpose, item: item, name: "リモコン")).not_to be_valid
      expect(build(:item_purpose, item: create(:item), name: "リモコン")).to be_valid
    end

    it "name は前後の空白 (全角スペースを含む) を落とす" do
      purpose = create(:item_purpose, item: item, name: "　リモコン ")

      expect(purpose.name).to eq "リモコン"
    end

    it "name は 50 文字まで" do
      expect(build(:item_purpose, item: item, name: "あ" * 50)).to be_valid
      expect(build(:item_purpose, item: item, name: "あ" * 51)).not_to be_valid
    end

    it "default_quantity は 1 以上" do
      expect(build(:item_purpose, item: item, default_quantity: 0)).not_to be_valid
      expect(build(:item_purpose, item: item, default_quantity: 1)).to be_valid
    end

    it "4 バイト整数をはみ出す default_quantity でも例外にならず検証エラーになる" do
      purpose = build(:item_purpose, item: item, default_quantity: 99_999_999_999)

      expect(purpose).not_to be_valid
      expect(purpose.errors[:default_quantity]).to be_present
    end
  end

  describe "並び順 (品目ごと)" do
    it "作成順に position が振られる" do
      first = create(:item_purpose, item: item, name: "リモコン")
      second = create(:item_purpose, item: item, name: "時計")

      expect([ first.position, second.position ]).to eq [ 1, 2 ]
    end

    # 品目ごとに 1 から振る。全体で連番にすると、別の品目の用途の数で並び順が変わる
    it "position は品目ごとに 1 から振られる" do
      create(:item_purpose, item: create(:item), name: "ほかの品目の用途")

      expect(create(:item_purpose, item: item, name: "リモコン").position).to eq 1
    end

    it ".ordered は position 順で返す" do
      second = create(:item_purpose, item: item, name: "時計")
      first = create(:item_purpose, item: item, name: "リモコン")
      first.move!(:up)

      expect(item.item_purposes.ordered.pluck(:name)).to eq [ "リモコン", "時計" ]
      expect(second.reload.position).to eq 2
    end

    it "#move! :up で 1 つ上と入れ替わる" do
      first = create(:item_purpose, item: item, name: "リモコン")
      second = create(:item_purpose, item: item, name: "時計")

      expect(second.move!(:up)).to be true
      expect(item.item_purposes.ordered.pluck(:name)).to eq [ "時計", "リモコン" ]
      expect(first.reload.position).to eq 2
    end

    it "端では false を返して何もしない" do
      first = create(:item_purpose, item: item, name: "リモコン")
      create(:item_purpose, item: item, name: "時計")

      expect(first.move!(:up)).to be false
      expect(item.item_purposes.ordered.pluck(:name)).to eq [ "リモコン", "時計" ]
    end

    it "未知の方向では何もしない" do
      purpose = create(:item_purpose, item: item, name: "リモコン")

      expect(purpose.move!("sideways")).to be false
    end

    # 並べ替えは品目の中だけで閉じる。他の品目の用途と入れ替わってはいけない
    it "他の品目の用途とは入れ替わらない" do
      other = create(:item, tracks_purposes: true)
      other_purpose = create(:item_purpose, item: other, name: "ほかの用途")
      create(:item_purpose, item: item, name: "リモコン")
      mine = create(:item_purpose, item: item, name: "時計")

      expect(mine.move!(:up)).to be true
      expect(other_purpose.reload.position).to eq 1
      expect(other.item_purposes.ordered.pluck(:name)).to eq [ "ほかの用途" ]
    end

    # アーカイブ済みは一覧に出ないので、間に挟まっていても入れ替え相手にしない
    # (相手にすると「上へ」を押しても画面の並びが変わらない)
    it "アーカイブ済みの用途は並べ替えの対象にならない" do
      create(:item_purpose, item: item, name: "リモコン")
      archived = create(:item_purpose, item: item, name: "むかしの用途")
      third = create(:item_purpose, item: item, name: "時計")
      archived.archive!

      expect(third.move!(:up)).to be true
      expect(item.item_purposes.active.ordered.pluck(:name)).to eq [ "時計", "リモコン" ]
    end

    it "アーカイブを解除した用途は末尾に並ぶ" do
      first = create(:item_purpose, item: item, name: "リモコン")
      create(:item_purpose, item: item, name: "時計")
      first.archive!

      first.restore!

      expect(item.item_purposes.active.ordered.pluck(:name)).to eq [ "時計", "リモコン" ]
    end

    # 採番はアーカイブ済みも含めた末尾から (戻したときに position が重ならないように)
    it "アーカイブ済みがあっても、新しい用途の position は重ならない" do
      create(:item_purpose, item: item, name: "リモコン")
      create(:item_purpose, :archived, item: item, name: "むかしの用途")

      expect(create(:item_purpose, item: item, name: "時計").position).to eq 3
    end

    it "並べ替えても updated_at を汚さない" do
      create(:item_purpose, item: item, name: "リモコン")
      second = create(:item_purpose, item: item, name: "時計")

      expect { second.move!(:up) }.not_to change { second.reload.updated_at }
    end
  end

  describe "アーカイブ" do
    it "#archive! は行を消さず archived_at を打つ" do
      purpose = create(:item_purpose, item: item)

      expect { purpose.archive! }.not_to change { described_class.count }
      expect(purpose.reload).to be_archived
    end

    it "二重に呼んでも日時を上書きしない" do
      purpose = create(:item_purpose, item: item, archived_at: 3.days.ago)
      archived_at = purpose.archived_at

      purpose.archive!

      expect(purpose.reload.archived_at).to eq archived_at
    end

    it "#restore! は archived_at を戻す" do
      purpose = create(:item_purpose, :archived, item: item)

      purpose.restore!

      expect(purpose.reload).not_to be_archived
    end

    it ".active はアーカイブされていないものだけ / .archived はその逆" do
      active = create(:item_purpose, item: item, name: "リモコン")
      archived = create(:item_purpose, :archived, item: item, name: "時計")

      expect(item.item_purposes.active).to contain_exactly(active)
      expect(item.item_purposes.archived).to contain_exactly(archived)
    end
  end

  # 用途を消すと、その用途で交換した履歴と交換周期まで失われる
  # (docs/spec/01-domain-model.md 3 節)
  describe "削除" do
    it "使用の記録が無ければ削除できる" do
      purpose = create(:item_purpose, item: item)

      expect { purpose.destroy }.to change { described_class.count }.by(-1)
    end

    it "使用の記録がある用途は削除できず、理由が分かるエラーになる" do
      purpose = create(:item_purpose, item: item)
      create(:usage_record, item: item, item_purpose: purpose)

      expect { purpose.destroy }.not_to change { described_class.count }
      expect(purpose.errors.full_messages.join).to include "削除できません"
    end

    # on_delete: :restrict は SQLSTATE 23001 (restrict_violation) なので、Rails は
    # 23503 だけを変換する InvalidForeignKey ではなく StatementInvalid を上げる
    it "コールバックを通らない delete でも外部キーで止まる" do
      purpose = create(:item_purpose, item: item)
      create(:usage_record, item: item, item_purpose: purpose)

      expect {
        described_class.transaction(requires_new: true) { purpose.delete }
      }.to raise_error(ActiveRecord::StatementInvalid, /RestrictViolation/)
    end

    it "品目ごと削除するときは、使用記録が紐づいていても用途も一緒に消える" do
      purpose = create(:item_purpose, item: item)
      create(:usage_record, item: item, item_purpose: purpose)

      expect { item.destroy }.to change { described_class.count }.by(-1)
      expect(UsageRecord.count).to eq 0
    end
  end

  # 交換周期は同一用途の used_on の差分の中央値 (docs/spec/01-domain-model.md 判断 4)
  describe "#replacement_interval_days" do
    let(:purpose) { create(:item_purpose, item: item, name: "リモコン") }

    def use_on(*dates)
      dates.each { |date| create(:usage_record, item: item, item_purpose: purpose, used_on: date) }
      purpose.reload
    end

    it "使用記録が 1 件なら nil (最終使用日だけ)" do
      use_on(Date.current - 30)

      expect(purpose.replacement_interval_days).to be_nil
      expect(purpose.last_used_on).to eq Date.current - 30
    end

    it "使用記録が無ければ最終使用日も nil" do
      expect(purpose.last_used_on).to be_nil
      expect(purpose.replacement_interval_days).to be_nil
    end

    it "2 件なら差分そのものを返す" do
      use_on(Date.current - 90, Date.current - 30)

      expect(purpose.replacement_interval_days).to eq 60
    end

    # 平均 (140/3 ≒ 47) ではなく中央値。外れ値 1 件で周期が伸びない
    it "差分の中央値を返す (平均ではない)" do
      use_on(Date.current - 200, Date.current - 170, Date.current - 140, Date.current - 60)

      expect(purpose.replacement_interval_days).to eq 30
    end

    it "差分が偶数個なら中央 2 つの平均になる" do
      # 差分は 10 / 20 / 30 / 50 の 4 つ。中央 2 つ (20 と 30) の平均で 25
      use_on(Date.current - 110, Date.current - 100, Date.current - 80, Date.current - 50, Date.current)

      expect(purpose.replacement_interval_days).to eq 25
    end

    # 同じ日に 2 回記録しても「周期 0 日」にしない
    it "同じ日の記録は 1 回と数える" do
      use_on(Date.current - 60, Date.current, Date.current)

      expect(purpose.replacement_interval_days).to eq 60
    end

    it "他の用途の記録は混ざらない" do
      other = create(:item_purpose, item: item, name: "時計")
      create(:usage_record, item: item, item_purpose: other, used_on: Date.current - 1)
      use_on(Date.current - 90, Date.current - 30)

      expect(purpose.replacement_interval_days).to eq 60
    end

    it "用途なしの記録も混ざらない" do
      create(:usage_record, item: item, item_purpose: nil, used_on: Date.current - 1)
      use_on(Date.current - 90, Date.current - 30)

      expect(purpose.replacement_interval_days).to eq 60
    end
  end

  describe "DB の制約" do
    # 例外でテスト用トランザクションが壊れないよう SAVEPOINT の中で試す
    it "default_quantity を 0 にする UPDATE は check 制約で弾かれる" do
      purpose = create(:item_purpose, item: item, default_quantity: 2)

      expect {
        described_class.transaction(requires_new: true) { purpose.update_column(:default_quantity, 0) }
      }.to raise_error(ActiveRecord::StatementInvalid)

      expect(purpose.reload.default_quantity).to eq 2
    end

    # insert_all は ON CONFLICT DO NOTHING を付けるので一意制約違反を黙って捨てる。
    # 制約が効いていることを確かめたいので insert_all! (ON CONFLICT なし) で試す
    it "同じ品目に同じ名前の用途を INSERT できない (一意 index)" do
      create(:item_purpose, item: item, name: "リモコン")

      expect {
        described_class.transaction(requires_new: true) {
          described_class.insert_all!([ { item_id: item.id, name: "リモコン", default_quantity: 1,
                                          position: 9, created_at: Time.current, updated_at: Time.current } ])
        }
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
