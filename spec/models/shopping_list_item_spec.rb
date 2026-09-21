require "rails_helper"

RSpec.describe ShoppingListItem do
  describe "バリデーション" do
    it "品目があれば自由入力は要らない" do
      expect(build(:shopping_list_item)).to be_valid
    end

    # belongs_to は保存の直前に未保存の親を保存するので、検証の時点では item_id が nil になる。
    # item_id だけを見て「自由入力の行」と決めつけると、ここで自由入力を求めてしまう
    it "未保存の品目を関連に入れただけの行 (item_id はまだ nil) も品目つきとして扱う" do
      entry = build(:shopping_list_item)

      expect(entry.item_id).to be_nil
      expect(entry.item).to be_present
      expect(entry).to be_valid
    end

    it "品目が無ければ自由入力が要る" do
      entry = build(:shopping_list_item, item: nil, free_text: nil)

      expect(entry).not_to be_valid
      expect(entry.errors[:free_text]).to be_present
    end

    it "自由入力は前後の空白 (全角を含む) を落とす" do
      entry = create(:shopping_list_item, :free_text, free_text: "　はがき ")

      expect(entry.free_text).to eq "はがき"
    end

    it "空白だけの自由入力は登録できない" do
      expect(build(:shopping_list_item, item: nil, free_text: "　 ")).not_to be_valid
    end

    it "自由入力の長さには上限がある" do
      entry = build(:shopping_list_item, :free_text,
        free_text: "あ" * (described_class::MAX_FREE_TEXT_LENGTH + 1))

      expect(entry).not_to be_valid
    end

    it "品目を選んだ行に自由入力は残さない" do
      entry = create(:shopping_list_item, free_text: "のこらない")

      expect(entry.free_text).to be_nil
    end

    it "希望数量は 1 以上の整数" do
      expect(build(:shopping_list_item, quantity: 0)).not_to be_valid
      expect(build(:shopping_list_item, quantity: 1)).to be_valid
    end

    it "希望数量は空でよい (推奨数量を使う)" do
      expect(build(:shopping_list_item, quantity: nil)).to be_valid
    end

    it "4 バイト整数をはみ出す希望数量でも例外にならず検証エラーになる" do
      entry = build(:shopping_list_item, quantity: 99_999_999_999)

      expect { entry.valid? }.not_to raise_error
      expect(entry).not_to be_valid
    end

    it "同じ品目の行は 2 つ作れない" do
      item = create(:item)
      create(:shopping_list_item, item: item)

      expect(build(:shopping_list_item, item: item)).not_to be_valid
    end

    it "自由入力の行は何件でも作れる" do
      create(:shopping_list_item, :free_text)

      expect(build(:shopping_list_item, :free_text)).to be_valid
    end

    it "存在しない品目を指していたら検証エラーにする (外部キー違反で 500 にしない)" do
      # 壊れた値 (uuid に cast できず nil になる) と、形は正しいが存在しない UUID の両方
      expect(build(:shopping_list_item, item_id: 0)).not_to be_valid
      expect(build(:shopping_list_item, item_id: nonexistent_uuid)).not_to be_valid
    end
  end

  describe "スヌーズ" do
    before { freeze_time }

    it "snoozed_until が today と同じ日はまだスヌーズ中" do
      entry = build(:shopping_list_item, snoozed_until: Date.current)

      expect(entry.snoozed?(Date.current)).to be true
    end

    it "snoozed_until が前日ならスヌーズは切れている" do
      entry = build(:shopping_list_item, snoozed_until: Date.current - 1)

      expect(entry.snoozed?(Date.current)).to be false
    end

    it "snoozed_until が空ならスヌーズしていない" do
      expect(build(:shopping_list_item).snoozed?(Date.current)).to be false
    end
  end

  # 掃除の条件は SQL の側に置く (メモリ上の値で判断して destroy すると、
  # 自分が読んだあとに他の人が付けたチェックごと消してしまう)
  describe ".blank_for_items" do
    it "何の意図も残っていない品目の行を返す" do
      entry = create(:shopping_list_item)

      expect(described_class.blank_for_items(Date.current)).to eq [ entry ]
    end

    it "チェック済み・数量の上書き・スヌーズ中・手動追加の行は返さない" do
      create(:shopping_list_item, :checked)
      create(:shopping_list_item, quantity: 2)
      create(:shopping_list_item, :snoozed)
      create(:shopping_list_item, :manual)

      expect(described_class.blank_for_items(Date.current)).to be_empty
    end

    it "スヌーズが切れた行は返す (当日はまだ切れていない)" do
      entry = create(:shopping_list_item, snoozed_until: Date.current - 1)
      create(:shopping_list_item, snoozed_until: Date.current)

      expect(described_class.blank_for_items(Date.current)).to eq [ entry ]
    end

    it "自由入力の行は返さない (品目が無いと導出からは出てこない)" do
      create(:shopping_list_item, :free_text, added_manually: false)

      expect(described_class.blank_for_items(Date.current)).to be_empty
    end
  end

  describe ".settle_after_purchase!" do
    # 数量の上書きだけが残った行を放っておくと、数か月後にまた urgent に戻ったときに
    # 古い上書きが復活する (docs/spec/01-domain-model.md 判断 5)
    it "購入を記録した品目の行は、チェックも上書きも手動の印もまとめて片づける" do
      item = create(:item)
      create(:shopping_list_item, :checked, :manual, item: item, quantity: 9)

      expect { described_class.settle_after_purchase!(item) }
        .to change(described_class, :count).by(-1)
    end

    it "他の品目の行と自由入力の行は残す" do
      item = create(:item)
      create(:shopping_list_item, item: item)
      other = create(:shopping_list_item, :checked)
      free_text = create(:shopping_list_item, :free_text, :checked)

      described_class.settle_after_purchase!(item)

      expect(described_class.pluck(:id)).to match_array [ other.id, free_text.id ]
    end
  end

  describe ".purge_stale!" do
    it "アーカイブ済みの品目の行は、チェック済みでも手動でも消す (一覧に出ないため)" do
      entry = create(:shopping_list_item, :checked, :manual, item: create(:item, :archived))

      expect { described_class.purge_stale!(Date.current) }.to change(described_class, :count).by(-1)
      expect(described_class.exists?(entry.id)).to be false
    end

    it "スヌーズが切れていて他に何も残っていない行は消す" do
      create(:shopping_list_item, snoozed_until: Date.current - 1)

      expect { described_class.purge_stale!(Date.current) }.to change(described_class, :count).by(-1)
    end

    it "スヌーズ中の行は消さない" do
      create(:shopping_list_item, :snoozed)

      expect { described_class.purge_stale!(Date.current) }.not_to change(described_class, :count)
    end

    it "チェック済み・数量の上書き・手動追加・自由入力の行は消さない" do
      create(:shopping_list_item, :checked)
      create(:shopping_list_item, quantity: 3)
      create(:shopping_list_item, :manual)
      create(:shopping_list_item, :free_text)

      expect { described_class.purge_stale!(Date.current) }.not_to change(described_class, :count)
    end
  end

  describe "DB の制約" do
    # 例外でテスト用トランザクションが壊れないよう SAVEPOINT の中で試す
    it "品目も自由入力も無い行は check 制約で弾かれる" do
      user = create(:user)

      expect {
        described_class.transaction(requires_new: true) do
          described_class.insert_all!([ { added_by_id: user.id,
                                          created_at: Time.current, updated_at: Time.current } ])
        end
      }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "同じ品目の行を 2 件入れる INSERT は部分一意 index で弾かれる" do
      entry = create(:shopping_list_item)

      expect {
        described_class.transaction(requires_new: true) do
          described_class.insert_all!([ { item_id: entry.item_id, added_by_id: entry.added_by_id,
                                          created_at: Time.current, updated_at: Time.current } ])
        end
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "自由入力の行は item_id が NULL なので何件でも入る (部分一意 index の対象外)" do
      entry = create(:shopping_list_item, :free_text)

      expect {
        described_class.insert_all!([ { free_text: "べつのもの", added_by_id: entry.added_by_id,
                                        created_at: Time.current, updated_at: Time.current } ])
      }.to change(described_class, :count).by(1)
    end

    # 23503 だけを変換する InvalidForeignKey ではなく StatementInvalid を上げる
    it "行が残っているユーザーは削除できない (restrict)" do
      entry = create(:shopping_list_item)

      expect {
        described_class.transaction(requires_new: true) { entry.added_by.delete }
      }.to raise_error(ActiveRecord::StatementInvalid, /RestrictViolation/)
    end

    it "行が残っている品目は削除できない (restrict)" do
      entry = create(:shopping_list_item)

      expect {
        described_class.transaction(requires_new: true) { entry.item.delete }
      }.to raise_error(ActiveRecord::StatementInvalid, /RestrictViolation/)
    end
  end
end
