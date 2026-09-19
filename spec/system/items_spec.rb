require "rails_helper"

RSpec.describe "品目", type: :system do
  let(:user) { create(:user) }

  it "品目を登録して詳細を見られる" do
    create(:category, name: "日用品")
    create(:storage_location, name: "洗面所")
    sign_in_as user

    click_link "品目"
    click_link "品目を追加"
    fill_in "名前", with: "トイレットペーパー"
    fill_in "よみ", with: "といれっとぺーぱー"
    select "日用品", from: "カテゴリ"
    select "洗面所", from: "保管場所"
    fill_in "単位", with: "ロール"
    click_button "登録する"

    expect(page).to have_text "「トイレットペーパー」を登録しました。"
    expect(page).to have_text "トイレットペーパー"
    expect(page).to have_text "日用品"
    expect(page).to have_text "洗面所"
    # 在庫は Phase 7 で動かす。いまは必ず 0
    within("section[aria-label='在庫']") do
      expect(page).to have_text "0"
      expect(page).to have_text "ロール"
    end
  end

  it "名前が空だとエラーを出してフォームに戻る" do
    sign_in_as user

    visit new_item_path
    fill_in "単位", with: "個"
    click_button "登録する"

    expect(page).to have_text "名前を入力してください"
    expect(Item.count).to eq 0
  end

  it "予測設定は畳まれた中にあり、開いて設定できる" do
    item = create(:item, name: "くん煙剤")
    sign_in_as user

    visit edit_item_path(item)

    # 閉じた details の中身は (summary を除いて) 不可視。rack_test も同じ扱いをする
    expect(page).to have_no_field("使用間隔 (日)")
    expect(page).to have_field("使用間隔 (日)", visible: :all)

    # summary をクリックすると rack_test でも details が開く (open 属性が付く)
    find("summary", text: "予測と期限の設定").click

    expect(page).to have_field("使用間隔 (日)")
    choose "手動"
    fill_in "使用間隔 (日)", with: "180"
    fill_in "最低在庫数", with: "1"
    check "期限を管理する"
    click_button "保存"

    expect(page).to have_text "「くん煙剤」を更新しました。"
    item.reload
    expect(item.estimation_mode).to eq "manual"
    expect(item.manual_interval_days).to eq 180
    expect(item.minimum_quantity).to eq 1
    expect(item).to be_tracks_expiry
  end

  it "予測設定は details に畳んである (スマホで邪魔にならない)" do
    sign_in_as user

    visit new_item_path

    expect(page).to have_css("details summary", text: "予測と期限の設定")
    expect(page).to have_no_css("details[open]")
    # 畳まれていることが見た目でも分かるよう、開閉の印を出す
    expect(page).to have_css("details summary span[aria-hidden='true']", text: "▶")
  end

  describe "一覧" do
    it "名前で検索できる" do
      create(:item, name: "トイレットペーパー")
      create(:item, name: "キッチンペーパー")
      sign_in_as user

      visit items_path
      fill_in "検索", with: "トイレット"
      click_button "絞り込む"

      within("ul[aria-label='品目一覧']") do
        expect(page).to have_text "トイレットペーパー"
        expect(page).to have_no_text "キッチンペーパー"
      end
    end

    it "カテゴリで絞り込める" do
      create(:item, name: "ラップ", category: create(:category, name: "キッチン"))
      create(:item, name: "シャンプー", category: create(:category, name: "おふろ"))
      sign_in_as user

      visit items_path
      select "キッチン", from: "カテゴリ"
      click_button "絞り込む"

      within("ul[aria-label='品目一覧']") do
        expect(page).to have_text "ラップ"
        expect(page).to have_no_text "シャンプー"
      end
    end

    it "1 件も当たらないときはその旨が出る" do
      create(:item, name: "ティッシュ")
      sign_in_as user

      visit items_path
      fill_in "検索", with: "ぜったいにない"
      click_button "絞り込む"

      expect(page).to have_text "条件に合う品目が見つかりません。"
    end
  end

  describe "アーカイブ" do
    it "アーカイブすると一覧から外れ、詳細から戻せる" do
      item = create(:item, name: "むかしの洗剤")
      sign_in_as user

      visit item_path(item)
      click_button "アーカイブする"
      expect(page).to have_text "アーカイブしました"

      # flash に名前が出るので、一覧の中を見て確かめる
      visit items_path
      expect(page).to have_no_css("ul[aria-label='品目一覧']", text: "むかしの洗剤")
      expect(page).to have_text "条件に合う品目が見つかりません。"

      visit item_path(item)
      expect(page).to have_text "この品目はアーカイブ済みです"
      click_button "アーカイブを解除"

      visit items_path
      within("ul[aria-label='品目一覧']") { expect(page).to have_text "むかしの洗剤" }
    end

    it "状態を切り替えるとアーカイブ済みの品目も一覧できる" do
      create(:item, :archived, name: "むかしの洗剤")
      sign_in_as user

      visit items_path
      select "アーカイブ済み", from: "状態"
      click_button "絞り込む"

      within("ul[aria-label='品目一覧']") { expect(page).to have_text "むかしの洗剤" }
    end

    it "品目を物理削除するボタンは無い" do
      item = create(:item)
      sign_in_as user

      visit item_path(item)

      expect(page).to have_no_button "削除する"
    end
  end
end
