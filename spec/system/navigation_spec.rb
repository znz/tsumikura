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
      expect(page).to have_text("品目")
      expect(page).to have_text("買い物")
      expect(page).to have_text("記録")
    end
  end

  it "未実装のタブ (品目・買い物・記録) はリンクにせず、準備中だと伝える" do
    sign_in_as create(:user)

    within(tab_bar) do
      expect(page).to have_no_link("品目")
      expect(page).to have_no_link("買い物")
      expect(page).to have_no_link("記録")
      expect(page).to have_css("[role='link'][aria-disabled='true']", count: 3)
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
