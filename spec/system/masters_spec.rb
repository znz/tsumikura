require "rails_helper"

RSpec.describe "マスタ", type: :system do
  let(:user) { create(:user) }

  describe "カテゴリ" do
    it "メニューから追加できる" do
      sign_in_as user

      click_link "メニュー"
      click_link "カテゴリ"
      click_link "カテゴリを追加"
      fill_in "名前", with: "日用品"
      click_button "追加"

      expect(page).to have_text "カテゴリ「日用品」を追加しました。"
      within("ul[aria-label='カテゴリ一覧']") { expect(page).to have_text "日用品" }
    end

    it "「上へ」で並べ替えできる (JS なし)" do
      create(:category, name: "食品")
      create(:category, name: "日用品")
      sign_in_as user

      visit categories_path
      within("ul[aria-label='カテゴリ一覧'] li", text: "日用品") { click_button "上へ" }

      expect(page).to have_css("ul[aria-label='カテゴリ一覧'] li:first-child", text: "日用品")
    end

    it "並べ替えボタンのアクセシブルネームに行の名前が入る" do
      create(:category, name: "食品")
      create(:category, name: "日用品")
      sign_in_as user

      visit categories_path

      expect(page).to have_css("button[aria-label='「日用品」を上へ']")
      expect(page).to have_css("button[aria-label='「食品」を下へ']")
    end

    it "先頭の「上へ」と末尾の「下へ」は押せない" do
      create(:category, name: "食品")
      create(:category, name: "日用品")
      sign_in_as user

      visit categories_path

      within("ul[aria-label='カテゴリ一覧'] li", text: "食品") do
        expect(page).to have_button("上へ", disabled: true)
        expect(page).to have_button("下へ", disabled: false)
      end
      within("ul[aria-label='カテゴリ一覧'] li", text: "日用品") do
        expect(page).to have_button("下へ", disabled: true)
      end
    end

    it "削除する前に、外れる品目の件数が画面に出る" do
      category = create(:category, name: "日用品")
      create(:item, category: category, name: "トイレットペーパー")
      sign_in_as user

      visit categories_path
      within("ul[aria-label='カテゴリ一覧'] li", text: "日用品") { click_link "編集" }

      expect(page).to have_text "1 件の品目からカテゴリが外れます"
    end

    it "削除すると品目は残り、カテゴリだけが外れる" do
      category = create(:category, name: "日用品")
      item = create(:item, category: category, name: "トイレットペーパー")
      sign_in_as user

      visit edit_category_path(category)
      click_button "削除する"

      expect(page).to have_text "1 件の品目からカテゴリが外れました"
      expect(page).to have_text "まだカテゴリがありません。"
      expect(item.reload.category).to be_nil
    end
  end

  describe "保管場所" do
    it "追加して並べ替えできる" do
      create(:storage_location, name: "洗面所")
      sign_in_as user

      visit storage_locations_path
      click_link "保管場所を追加"
      fill_in "名前", with: "パントリー"
      click_button "追加"

      expect(page).to have_css("ul[aria-label='保管場所一覧'] li:first-child", text: "洗面所")

      within("ul[aria-label='保管場所一覧'] li", text: "パントリー") { click_button "上へ" }

      expect(page).to have_css("ul[aria-label='保管場所一覧'] li:first-child", text: "パントリー")
    end
  end

  describe "店舗" do
    it "メモつきで追加できる" do
      sign_in_as user

      visit stores_path
      click_link "店舗を追加"
      fill_in "名前", with: "あおぞらスーパー"
      fill_in "メモ", with: "駅前。日曜は混む"
      click_button "追加"

      within("ul[aria-label='店舗一覧']") do
        expect(page).to have_text "あおぞらスーパー"
        expect(page).to have_text "駅前。日曜は混む"
      end
    end

    it "削除できる" do
      store = create(:store, name: "やおや")
      sign_in_as user

      visit edit_store_path(store)
      click_button "削除する"

      expect(page).to have_text "店舗「やおや」を削除しました。"
      expect(page).to have_text "まだ店舗がありません。"
    end
  end
end
