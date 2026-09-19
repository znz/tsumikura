require "rails_helper"

RSpec.describe "品目のアーカイブ", type: :request do
  let(:user) { create(:user) }

  before { sign_in user }

  describe "POST (アーカイブ)" do
    it "品目をアーカイブできる (レコードは消さない)" do
      item = create(:item)

      expect { post item_archive_path(item) }.not_to change { Item.count }

      expect(item.reload).to be_archived
      expect(response).to redirect_to item_path(item)
    end

    it "アーカイブした品目は一覧から外れる" do
      item = create(:item, name: "むかしの洗剤")
      post item_archive_path(item)
      # flash (「〜をアーカイブしました」) をリダイレクト先で消費してから一覧を見る。
      # さらに一覧要素の中だけを見て、flash 由来の偽陽性・偽陰性を二重に避ける
      follow_redirect!

      get items_path

      expect(rendered_list("品目一覧")).not_to include item.name
    end

    it "アーカイブした品目の詳細は開ける" do
      item = create(:item, name: "むかしの洗剤")
      post item_archive_path(item)

      get item_path(item)

      expect(response).to have_http_status(:ok)
      # flash にも名前が出るので、見出しで確かめる
      expect(response.parsed_body.at("h1").text).to include item.name
      expect(response.body).to include "この品目はアーカイブ済みです"
    end
  end

  describe "DELETE (復元)" do
    it "アーカイブを解除できる" do
      item = create(:item, :archived)

      delete item_archive_path(item)

      expect(item.reload).not_to be_archived
      expect(response).to redirect_to item_path(item)
    end

    it "解除すると一覧に戻る" do
      item = create(:item, :archived, name: "復活した洗剤")

      delete item_archive_path(item)
      follow_redirect!
      get items_path

      # flash は消費済みなので、名前が出るのは一覧の行としてだけ
      expect(response.body).not_to include "アーカイブを解除しました"
      expect(rendered_list("品目一覧")).to include item.name
    end
  end

  describe "品目の操作は管理者に限らない" do
    it "一般ユーザーでもアーカイブできる" do
      item = create(:item)

      post item_archive_path(item)

      expect(response).not_to have_http_status(:forbidden)
      expect(item.reload).to be_archived
    end
  end
end
