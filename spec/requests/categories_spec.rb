require "rails_helper"

RSpec.describe "カテゴリ", type: :request do
  let(:user) { create(:user) }

  before { sign_in user }

  describe "GET /categories" do
    it "並び順どおりに一覧できる" do
      first = create(:category, name: "日用品")
      second = create(:category, name: "食品")

      get categories_path

      expect(response).to have_http_status(:ok)
      list = rendered_list("カテゴリ一覧")
      expect(list.index(first.name)).to be < list.index(second.name)
    end

    it "紐づく品目の件数を出す" do
      category = create(:category, name: "日用品")
      create(:item, category: category)
      create(:item, category: category)
      create(:item)

      get categories_path

      expect(rendered_list("カテゴリ一覧")).to include "2 件"
    end

    it "品目が増えてもクエリ数は増えない" do
      category = create(:category)
      create(:item, category: category)
      get categories_path # ウォームアップ

      baseline = count_queries { get categories_path }
      3.times { create(:item, category: create(:category)) }

      expect(count_queries { get categories_path }).to eq baseline
    end
  end

  describe "POST /categories" do
    it "カテゴリを追加できる" do
      expect {
        post categories_path, params: { category: { name: "日用品" } }
      }.to change { Category.count }.by(1)

      expect(response).to redirect_to categories_path
    end

    it "追加したカテゴリは末尾に並ぶ" do
      first = create(:category, name: "食品")

      post categories_path, params: { category: { name: "日用品" } }

      expect(Category.ordered.map(&:name)).to eq [ first.name, "日用品" ]
    end

    it "名前が空なら追加できない" do
      expect {
        post categories_path, params: { category: { name: "" } }
      }.not_to change { Category.count }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "同じ名前は追加できない" do
      create(:category, name: "日用品")

      expect {
        post categories_path, params: { category: { name: "日用品" } }
      }.not_to change { Category.count }

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "PATCH /categories/:id" do
    it "名前を変更できる" do
      category = create(:category, name: "日用品")

      patch category_path(category), params: { category: { name: "生活用品" } }

      expect(category.reload.name).to eq "生活用品"
      expect(response).to redirect_to categories_path
    end

    it "並び順はフォームからは変更できない" do
      first = create(:category)
      second = create(:category)

      patch category_path(second), params: { category: { name: "あたらしい名前", position: 0 } }

      expect(Category.ordered.to_a).to eq [ first, second.reload ]
    end
  end

  describe "PATCH /categories/:id/position (並べ替え)" do
    it "上へ移動できる" do
      first = create(:category)
      second = create(:category)

      patch category_position_path(second), params: { direction: "up" }

      expect(Category.ordered.to_a).to eq [ second, first ]
      expect(response).to redirect_to categories_path
    end

    it "下へ移動できる" do
      first = create(:category)
      second = create(:category)

      patch category_position_path(first), params: { direction: "down" }

      expect(Category.ordered.to_a).to eq [ second, first ]
    end

    it "先頭を上へ移動しても並びは変わらない" do
      first = create(:category)
      second = create(:category)

      patch category_position_path(first), params: { direction: "up" }

      expect(Category.ordered.to_a).to eq [ first, second ]
      expect(response).to redirect_to categories_path
    end

    it "知らない方向が来ても並びは変わらない" do
      first = create(:category)
      second = create(:category)

      patch category_position_path(second), params: { direction: "sideways" }

      expect(Category.ordered.to_a).to eq [ first, second ]
    end
  end

  describe "DELETE /categories/:id" do
    it "削除しても品目は消えず、カテゴリだけが外れる" do
      category = create(:category, name: "日用品")
      item = create(:item, category: category)

      expect { delete category_path(category) }.not_to change { Item.count }

      expect(item.reload.category_id).to be_nil
      expect(Category.exists?(category.id)).to be false
      expect(response).to redirect_to categories_path
    end

    it "アーカイブ済みの品目からも外れる" do
      category = create(:category)
      item = create(:item, :archived, category: category)

      delete category_path(category)

      expect(item.reload.category_id).to be_nil
    end

    it "外れた品目の件数を知らせる" do
      category = create(:category, name: "日用品")
      create(:item, category: category)
      create(:item, category: category)

      delete category_path(category)

      expect(flash[:notice]).to include "2 件"
    end

    it "削除前に、外れる品目の件数を編集画面で知らせる" do
      category = create(:category, name: "日用品")
      create(:item, category: category)
      create(:item, category: category)

      get edit_category_path(category)

      expect(response.body).to include "2 件の品目からカテゴリが外れます"
    end
  end
end
