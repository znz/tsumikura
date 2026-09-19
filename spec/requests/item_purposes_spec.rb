require "rails_helper"

RSpec.describe "用途マスタ", type: :request do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:user) { create(:user) }
  let(:item) { create(:item, name: "単 3 電池", unit: "本", tracks_purposes: true) }

  before { sign_in user }

  describe "GET /items/:item_id/purposes (一覧)" do
    it "その品目の用途だけが並ぶ" do
      create(:item_purpose, item: item, name: "リモコン")
      create(:item_purpose, item: create(:item), name: "ほかの品目の用途")

      get item_purposes_path(item)

      expect(response).to have_http_status(:ok)
      expect(rendered_list("用途一覧")).to include "リモコン"
      expect(rendered_list("用途一覧")).not_to include "ほかの品目の用途"
    end

    it "アーカイブ済みは別の一覧に出る" do
      create(:item_purpose, item: item, name: "リモコン")
      create(:item_purpose, :archived, item: item, name: "むかしの用途")

      get item_purposes_path(item)

      expect(rendered_list("用途一覧")).not_to include "むかしの用途"
      expect(rendered_list("アーカイブ済みの用途一覧")).to include "むかしの用途"
    end

    it "用途が無ければその旨を出す" do
      get item_purposes_path(item)

      expect(response.body).to include "まだ用途がありません"
    end

    it "最終交換日と使用件数が出る" do
      purpose = create(:item_purpose, item: item, name: "リモコン")
      create(:usage_record, item: item, item_purpose: purpose, used_on: Date.current - 10)

      get item_purposes_path(item)

      expect(rendered_list("用途一覧")).to include I18n.l(Date.current - 10)
      expect(rendered_list("用途一覧")).to include "使用 1 件"
    end

    it "存在しない品目は 404" do
      get item_purposes_path(item_id: 0)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /items/:item_id/purposes (追加)" do
    it "追加できる" do
      expect {
        post item_purposes_path(item), params: { item_purpose: { name: "リモコン", default_quantity: "2" } }
      }.to change { ItemPurpose.count }.by(1)

      purpose = ItemPurpose.order(:id).last
      expect(purpose.item).to eq item
      expect(purpose.default_quantity).to eq 2
      expect(response).to redirect_to item_purposes_path(item)
    end

    it "名前が空なら 422" do
      expect {
        post item_purposes_path(item), params: { item_purpose: { name: "" } }
      }.not_to change { ItemPurpose.count }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "同じ品目に同じ名前は追加できない" do
      create(:item_purpose, item: item, name: "リモコン")

      post item_purposes_path(item), params: { item_purpose: { name: "リモコン" } }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "4 バイト整数をはみ出す既定の数量でも 500 にならず 422" do
      post item_purposes_path(item), params: { item_purpose: { name: "リモコン", default_quantity: "99999999999" } }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "追加した用途は末尾に並ぶ" do
      create(:item_purpose, item: item, name: "リモコン")

      post item_purposes_path(item), params: { item_purpose: { name: "時計" } }

      expect(item.item_purposes.ordered.pluck(:name)).to eq [ "リモコン", "時計" ]
    end

    it "item_purpose キーが無ければ 400 (500 にしない)" do
      post item_purposes_path(item), params: { name: "リモコン" }

      expect(response).to have_http_status(:bad_request)
    end

    describe "フォームから変更できない項目" do
      it "並び順は変えられない (並べ替えは PositionsController の担当)" do
        post item_purposes_path(item), params: { item_purpose: { name: "リモコン", position: "99" } }

        expect(ItemPurpose.order(:id).last.position).to eq 1
      end

      it "アーカイブはフォームから設定できない" do
        post item_purposes_path(item),
          params: { item_purpose: { name: "リモコン", archived_at: Time.current.iso8601 } }

        expect(ItemPurpose.order(:id).last).not_to be_archived
      end

      it "品目は URL で決まる" do
        other = create(:item)

        post item_purposes_path(item), params: { item_purpose: { name: "リモコン", item_id: other.id } }

        expect(ItemPurpose.order(:id).last.item).to eq item
      end
    end
  end

  describe "PATCH /items/:item_id/purposes/:id (更新)" do
    let(:purpose) { create(:item_purpose, item: item, name: "リモコン") }

    it "名前と既定の数量を更新できる" do
      patch item_purpose_path(item, purpose), params: { item_purpose: { name: "テレビのリモコン", default_quantity: "2" } }

      expect(purpose.reload.name).to eq "テレビのリモコン"
      expect(purpose.default_quantity).to eq 2
    end

    it "他の品目の用途は更新できない (404)" do
      other = create(:item_purpose, item: create(:item), name: "ほかの用途")

      patch item_purpose_path(item, other), params: { item_purpose: { name: "のっとり" } }

      expect(response).to have_http_status(:not_found)
      expect(other.reload.name).to eq "ほかの用途"
    end
  end

  describe "DELETE /items/:item_id/purposes/:id (削除)" do
    it "使用の記録が無ければ削除できる" do
      purpose = create(:item_purpose, item: item)

      expect { delete item_purpose_path(item, purpose) }.to change { ItemPurpose.count }.by(-1)
      expect(response).to redirect_to item_purposes_path(item)
    end

    # 履歴を消さないための守り (docs/spec/01-domain-model.md 3 節)
    it "使用の記録がある用途は削除できず、その旨を知らせる" do
      purpose = create(:item_purpose, item: item, name: "リモコン")
      create(:usage_record, item: item, item_purpose: purpose)

      expect { delete item_purpose_path(item, purpose) }.not_to change { ItemPurpose.count }

      follow_redirect!
      expect(response.body).to include "削除できません"
    end
  end

  describe "並べ替え" do
    it "「上へ」で並びが変わる" do
      create(:item_purpose, item: item, name: "リモコン")
      second = create(:item_purpose, item: item, name: "時計")

      patch item_purpose_position_path(item, second), params: { direction: "up" }

      expect(item.item_purposes.ordered.pluck(:name)).to eq [ "時計", "リモコン" ]
      expect(response).to redirect_to item_purposes_path(item)
    end

    it "端では並びが変わらない" do
      first = create(:item_purpose, item: item, name: "リモコン")
      create(:item_purpose, item: item, name: "時計")

      patch item_purpose_position_path(item, first), params: { direction: "up" }

      expect(item.item_purposes.ordered.pluck(:name)).to eq [ "リモコン", "時計" ]
    end

    it "未知の方向でも 500 にならず並びが変わらない" do
      first = create(:item_purpose, item: item, name: "リモコン")
      create(:item_purpose, item: item, name: "時計")

      patch item_purpose_position_path(item, first), params: { direction: "sideways" }

      expect(response).to redirect_to item_purposes_path(item)
      expect(item.item_purposes.ordered.pluck(:name)).to eq [ "リモコン", "時計" ]
    end

    it "他の品目の用途は並べ替えられない (404)" do
      other = create(:item_purpose, item: create(:item))

      patch item_purpose_position_path(item, other), params: { direction: "up" }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "アーカイブ" do
    let(:purpose) { create(:item_purpose, item: item, name: "リモコン") }

    it "アーカイブすると一覧から外れるが、使用記録は残る" do
      create(:usage_record, item: item, item_purpose: purpose)

      expect { post item_purpose_archive_path(item, purpose) }.not_to change { UsageRecord.count }

      expect(purpose.reload).to be_archived
      follow_redirect!
      expect(rendered_list("用途一覧")).not_to include "リモコン"
    end

    it "アーカイブを解除できる" do
      purpose.archive!

      delete item_purpose_archive_path(item, purpose)

      expect(purpose.reload).not_to be_archived
    end

    it "他の品目の用途はアーカイブできない (404)" do
      other = create(:item_purpose, item: create(:item))

      post item_purpose_archive_path(item, other)

      expect(response).to have_http_status(:not_found)
      expect(other.reload).not_to be_archived
    end
  end
end
