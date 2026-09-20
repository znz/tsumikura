require "rails_helper"

RSpec.describe "グローバルナビ", type: :system do
  let(:tab_bar) { "nav[aria-label='グローバルナビ']" }

  it "未ログインのログイン画面にはタブを出さない" do
    visit new_session_path

    expect(page).to have_no_css(tab_bar)
  end

  it "ログインすると下部タブが表示される" do
    sign_in_as create(:user)

    within(tab_bar) do
      expect(page).to have_link("ホーム")
      expect(page).to have_link("メニュー")
      expect(page).to have_link("品目")
      expect(page).to have_link("買い物")
      expect(page).to have_link("記録")
    end
  end

  it "中央の「＋記録」から記録メニューに行ける" do
    sign_in_as create(:user)

    within(tab_bar) { click_link "記録" }

    expect(page).to have_current_path(record_menu_path)
    expect(page).to have_link("棚卸")
  end

  it "記録メニューと棚卸では記録タブがハイライトされる" do
    sign_in_as create(:user)

    [ record_menu_path, stock_takes_path, new_stock_take_path ].each do |path|
      visit path

      within(tab_bar) do
        expect(page).to have_css("a[aria-current='page']", text: "記録"), "#{path} で記録タブが現在地にならない"
      end
    end
  end

  it "品目タブから品目一覧に行ける" do
    sign_in_as create(:user)

    within(tab_bar) { click_link "品目" }

    expect(page).to have_current_path(items_path)
  end

  it "品目の詳細やフォームでも品目タブがハイライトされる" do
    item = create(:item)
    sign_in_as create(:user)

    lot = create(:lot, item: item)

    [ items_path, item_path(item), new_item_path, edit_item_path(item),
      new_item_lot_path(item), edit_lot_path(lot) ].each do |path|
      visit path

      within(tab_bar) do
        expect(page).to have_css("a[aria-current='page']", text: "品目"), "#{path} で品目タブが現在地にならない"
      end
    end
  end

  it "品目以外のページでは品目タブはハイライトされない" do
    sign_in_as create(:user)

    visit categories_path

    within(tab_bar) { expect(page).to have_no_css("a[aria-current='page']", text: "品目") }
  end

  it "買い物タブから買い物リストに行ける" do
    sign_in_as create(:user)

    within(tab_bar) { click_link "買い物" }

    expect(page).to have_current_path(shopping_list_path)
  end

  it "まとめ購入でも買い物タブがハイライトされる" do
    item = create(:item, minimum_quantity: 5)
    create(:lot, item: item, initial_quantity: 3)
    user = create(:user)
    create(:shopping_list_item, :checked, item: item, added_by: user)
    sign_in_as user

    [ shopping_list_path, new_purchase_path ].each do |path|
      visit path

      within(tab_bar) do
        expect(page).to have_css("a[aria-current='page']", text: "買い物"), "#{path} で買い物タブが現在地にならない"
      end
    end
  end

  it "下部タブはホームインジケータを避ける余白を持つ" do
    sign_in_as create(:user)

    expect(page).to have_css("#{tab_bar}[class*='safe-area-inset-bottom']")
  end

  describe "メニュー" do
    it "アカウント設定に行ける" do
      sign_in_as create(:user)

      click_link "メニュー"
      click_link "アカウント設定"

      expect(page).to have_current_path(account_path)
    end

    it "マスタ管理 (カテゴリ・保管場所・店舗) に行ける" do
      sign_in_as create(:user)

      click_link "メニュー"
      click_link "カテゴリ"
      expect(page).to have_current_path(categories_path)

      click_link "メニュー"
      click_link "保管場所"
      expect(page).to have_current_path(storage_locations_path)

      click_link "メニュー"
      click_link "店舗"
      expect(page).to have_current_path(stores_path)
    end

    it "棚卸に行ける" do
      sign_in_as create(:user)

      click_link "メニュー"
      click_link "棚卸"

      expect(page).to have_current_path(stock_takes_path)
    end

    it "管理者はユーザー管理に行ける" do
      sign_in_as create(:user, :admin)

      click_link "メニュー"
      click_link "ユーザー管理"

      expect(page).to have_current_path(admin_users_path)
    end

    it "一般ユーザーにはユーザー管理のリンクが見えない" do
      sign_in_as create(:user)

      click_link "メニュー"

      expect(page).to have_no_link("ユーザー管理")
    end

    it "ログアウトできる" do
      sign_in_as create(:user)

      click_link "メニュー"
      click_button "ログアウト"

      expect(page).to have_current_path(new_session_path)
    end
  end
end
