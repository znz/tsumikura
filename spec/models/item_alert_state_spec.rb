require "rails_helper"

RSpec.describe ItemAlertState do
  let(:item) { create(:item, name: "といれっとぺーぱー") }

  def entry(target = item, purchase: "urgent", expiry: "fresh")
    Notifications::Digest::Entry.new(item_id: target.id, name: target.name,
      purchase_status: purchase, expiry_status: expiry)
  end

  describe ".record!" do
    it "行が無ければ作る" do
      expect { described_class.record!([ entry ]) }.to change(described_class, :count).by 1
      expect(described_class.sole).to have_attributes(
        item_id: item.id, notified_purchase_status: "urgent", notified_expiry_status: "fresh"
      )
    end

    it "2 回目は同じ行を更新する (品目 1 件につき行は 1 つ)" do
      described_class.record!([ entry ])

      expect { described_class.record!([ entry(purchase: "ok") ]) }.not_to change(described_class, :count)
      expect(described_class.sole.notified_purchase_status).to eq "ok"
    end

    it "Symbol を渡しても文字列で保存する" do
      described_class.record!([ entry(purchase: :soon, expiry: :expired) ])

      expect(described_class.sole).to have_attributes(
        notified_purchase_status: "soon", notified_expiry_status: "expired"
      )
    end

    it "空の配列なら何もしない" do
      expect { described_class.record!([]) }.not_to change(described_class, :count)
    end

    it "品目が増えても UPSERT は 1 本のまま" do
      entries = Array.new(3) { entry(create(:item)) }

      expect(count_queries { described_class.record!(entries) }).to eq 1
    end

    it "突き合わせた時刻と timestamps が入る" do
      freeze_time do
        described_class.record!([ entry ])

        # upsert_all の timestamps は DB の CURRENT_TIMESTAMP で入るので、freeze_time の時刻とは一致しない
        state = described_class.sole
        expect(state.notified_at).to eq Time.current
        expect(state.created_at).to be_present
        expect(state.updated_at).to be_present
      end
    end
  end

  describe "品目との関連" do
    it "品目を物理削除しても外部キー違反にならない" do
      described_class.record!([ entry ])

      expect { item.destroy! }.to change(described_class, :count).from(1).to 0
    end
  end

  describe ".purge_archived!" do
    it "アーカイブ済みの品目の行を消す" do
      archived = create(:item, :archived)
      described_class.record!([ entry, entry(archived) ])

      expect { described_class.purge_archived! }.to change(described_class, :count).from(2).to 1
      expect(described_class.sole.item_id).to eq item.id
    end

    it "アーカイブされていない品目の行は残す" do
      described_class.record!([ entry ])

      expect { described_class.purge_archived! }.not_to change(described_class, :count)
    end
  end
end
