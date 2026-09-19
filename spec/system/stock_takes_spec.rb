require "rails_helper"

RSpec.describe "棚卸", type: :system do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:user) { create(:user) }
  let(:kitchen) { create(:storage_location, name: "台所") }
  let(:tab_bar) { "nav[aria-label='グローバルナビ']" }

  # 既定のドライバは rack_test (JS 無し)。JS が無くても棚卸を一巡できる
  describe "JS が無いとき" do
    it "保管場所を選んで数え、確定すると在庫が実数に一致する" do
      item = create(:item, name: "ラップ", unit: "本", storage_location: kitchen)
      create(:lot, item: item, initial_quantity: 3)
      sign_in_as user

      within(tab_bar) { click_link "記録" }
      within("ul[aria-label='記録メニュー']") { click_link "棚卸" }

      select "台所", from: "保管場所"
      click_button "数え始める"

      expect(page).to have_text "記録在庫 3 本"
      fill_in "「ラップ」の実数", with: "1"
      click_button "確認へ進む"

      expect(page).to have_text "差分のまとめ"
      expect(page).to have_text "−2"

      click_button "この内容で確定する"

      expect(page).to have_text "増 0 件 / 減 1 件"
      expect(item.reload.current_quantity).to eq 1
    end

    it "実数が多ければ在庫が増え、調整のロットができる" do
      item = create(:item, name: "ラップ", unit: "本", storage_location: kitchen)
      create(:lot, item: item, initial_quantity: 3)
      sign_in_as user

      visit new_stock_take_path
      select "台所", from: "保管場所"
      click_button "数え始める"
      fill_in "「ラップ」の実数", with: "5"
      click_button "確認へ進む"
      click_button "この内容で確定する"

      expect(item.reload.current_quantity).to eq 5
      expect(item.lots.kind_adjustment.sole.initial_quantity).to eq 2
    end

    it "途中保存して続きから数えられる" do
      item = create(:item, name: "ラップ", unit: "本", storage_location: kitchen)
      create(:lot, item: item, initial_quantity: 3)
      sign_in_as user

      visit new_stock_take_path
      select "台所", from: "保管場所"
      click_button "数え始める"
      fill_in "「ラップ」の実数", with: "2"
      click_button "途中保存"

      expect(page).to have_text "途中まで保存しました"
      expect(page).to have_field("「ラップ」の実数", with: "2")
      expect(item.reload.current_quantity).to eq 3
    end

    it "未入力の品目は差分に出ず、在庫も変わらない" do
      counted = create(:item, name: "ラップ", unit: "本", storage_location: kitchen)
      skipped = create(:item, name: "アルミホイル", unit: "本", storage_location: kitchen)
      create(:lot, item: counted, initial_quantity: 3)
      create(:lot, item: skipped, initial_quantity: 4)
      sign_in_as user

      visit new_stock_take_path
      select "台所", from: "保管場所"
      click_button "数え始める"
      fill_in "「ラップ」の実数", with: "1"
      click_button "確認へ進む"
      click_button "この内容で確定する"

      expect(counted.reload.current_quantity).to eq 1
      expect(skipped.reload.current_quantity).to eq 4
    end

    it "下書きは削除でき、在庫は変わらない" do
      item = create(:item, name: "ラップ", storage_location: kitchen)
      create(:lot, item: item, initial_quantity: 3)
      sign_in_as user

      visit new_stock_take_path
      select "台所", from: "保管場所"
      click_button "数え始める"
      click_button "下書きを削除"

      expect(page).to have_text "棚卸の下書きを削除しました"
      expect(item.reload.current_quantity).to eq 3
      expect(StockTake.count).to eq 0
    end

    it "確定済みの棚卸には確定ボタンも削除ボタンも出ない" do
      sign_in_as user
      stock_take = create(:stock_take, :finalized, user: user, storage_location: kitchen)

      visit stock_take_path(stock_take)

      expect(page).to have_no_button "この内容で確定する"
      expect(page).to have_no_button "下書きを削除"
      expect(page).to have_text "確定済み"
    end
  end

  # ロット別の入力は details に畳んである (JS が無くても開ける)
  it "期限を管理する品目はロット別に数えられる" do
    item = create(:item, :tracks_expiry, name: "たまご", unit: "個", storage_location: kitchen)
    near = create(:lot, item: item, initial_quantity: 6, expires_on: Date.current + 1)
    far = create(:lot, item: item, initial_quantity: 6, expires_on: Date.current + 30)
    sign_in_as user

    visit new_stock_take_path
    select "台所", from: "保管場所"
    click_button "数え始める"

    # 閉じた details の中身は (summary を除いて) 不可視。summary をクリックすると
    # rack_test でも details が開く (open 属性が付く)
    expect(page).to have_css("details summary", text: "ロット別に数える (2 件)")
    find("summary", text: "ロット別に数える").click

    fill_in "「たまご」の期限 #{I18n.l(near.expires_on)}のロットの実数", with: "4"
    click_button "確認へ進む"
    click_button "この内容で確定する"

    expect(near.reload.remaining_quantity).to eq 4
    expect(far.reload.remaining_quantity).to eq 6
    expect(item.reload.current_quantity).to eq 10
  end
end
