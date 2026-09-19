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
      expect(page).to have_text("買い物")
      expect(page).to have_text("記録")
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

    [ items_path, item_path(item), new_item_path, edit_item_path(item) ].each do |path|
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

  it "未実装のタブ (買い物・記録) はリンクにせず、準備中だと伝える" do
    sign_in_as create(:user)

    within(tab_bar) do
      expect(page).to have_no_link("買い物")
      expect(page).to have_no_link("記録")
      expect(page).to have_css("[role='link'][aria-disabled='true']", count: 2)
      expect(page).to have_text("準備中")
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
