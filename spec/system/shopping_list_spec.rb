require "rails_helper"

RSpec.describe "買い物リスト", type: :system do
  before { freeze_time }

  let(:user) { create(:user, name: "おかあさん") }

  def urgent_item(name:, **attributes)
    create(:item, name: name, minimum_quantity: 5, **attributes).tap { |item| stock_up(item, 3) }
  end

  it "下部タブから買い物リストを開ける" do
    sign_in_as user

    within("nav[aria-label='グローバルナビ']") { click_link "買い物" }

    expect(page).to have_current_path(shopping_list_path)
    expect(page).to have_css("h1", text: "買い物リスト")
  end

  it "ダッシュボードのアラートから買い物リストに行ける" do
    urgent_item(name: "ティッシュ")
    sign_in_as user

    click_link "買い物リストを開く"

    expect(page).to have_current_path(shopping_list_path)
  end

  it "品目詳細から買い物リストに追加できる" do
    item = stock_up(create(:item, name: "よびのでんち", minimum_quantity: 1), 10).item
    sign_in_as user

    visit item_path(item)
    click_button "買い物リストに追加"

    expect(page).to have_current_path(shopping_list_path)
    within("ul[aria-label='手動で追加した品目']") { expect(page).to have_text "よびのでんち" }
  end

  # JS 無し (rack_test) でも最後まで進めること
  it "チェックしてまとめ購入まで進める" do
    item = urgent_item(name: "ティッシュ")
    create(:store, name: "スーパー")
    sign_in_as user

    visit shopping_list_path
    click_button "「ティッシュ」をチェックする"

    click_link "チェック済み 1 件を購入として記録"
    fill_in "数量 (個)", with: "10"
    select "スーパー", from: "店舗"
    click_button "購入を記録"

    expect(page).to have_current_path(shopping_list_path)
    expect(page).to have_text "1 件の購入を記録しました"
    expect(item.reload.current_quantity).to eq 13
    expect(page).to have_no_css("ul[aria-label='要購入の品目']")
  end

  it "自由入力で買い物リストに書き足し、あとで消せる" do
    sign_in_as user

    visit shopping_list_path
    fill_in "リストに書き足す", with: "はがき"
    click_button "追加"

    # flash にも品目名が出るので、一覧の要素に絞って確かめる
    within("ul[aria-label='手動で追加した品目']") { expect(page).to have_text "はがき" }

    click_button "「はがき」をリストから外す"

    expect(page).to have_no_css("ul[aria-label='手動で追加した品目']")
  end

  it "今回は買わない (スヌーズ) と一覧から外れ、解除すると戻る" do
    urgent_item(name: "ティッシュ")
    sign_in_as user

    visit shopping_list_path
    click_button "「ティッシュ」を今回は買わない"

    expect(page).to have_no_css("ul[aria-label='要購入の品目']")
    expect(page).to have_css("summary", text: "スヌーズ中 (1 件)")

    # 閉じた details の中身は (summary を除いて) 不可視。
    # summary をクリックすると rack_test でも details が開く (open 属性が付く)
    find("summary", text: "スヌーズ中").click
    within("ul[aria-label='スヌーズ中の品目']") { expect(page).to have_text "ティッシュ" }

    click_button "「ティッシュ」のスヌーズを解除する"

    within("ul[aria-label='要購入の品目']") { expect(page).to have_text "ティッシュ" }
  end

  it "希望数量を上書きすると、まとめ購入の初期値になる" do
    urgent_item(name: "ティッシュ")
    sign_in_as user

    visit shopping_list_path
    click_button "「ティッシュ」をチェックする"
    within("#shopping_list_row_item_#{Item.sole.id}") do
      fill_in "希望数量", with: "9"
      click_button "保存"
    end

    click_link "チェック済み 1 件を購入として記録"

    expect(page).to have_field("数量 (個)", with: "9")
  end

  # チェックのボタンは button_to のフォームなので JS 無しでも動くが、
  # 実ブラウザ (Turbo あり) でも同じように動くことを確かめる
  it "実ブラウザでもチェックできる", js: true do
    urgent_item(name: "ティッシュ")
    sign_in_as user

    visit shopping_list_path
    click_button "「ティッシュ」をチェックする"

    expect(page).to have_button "「ティッシュ」のチェックを外す"
    expect(page).to have_link "チェック済み 1 件を購入として記録"
  end

  # 店頭で長いリストの下の方をチェックするたびに先頭へ戻ると使いものにならない
  # (morph + scroll: preserve と、リダイレクト先のアンカーの両方で効かせている)
  it "実ブラウザでチェックしてもスクロール位置が先頭に戻らない", js: true do
    12.times { |index| urgent_item(name: "しな#{format('%02d', index)}") }
    sign_in_as user

    visit shopping_list_path
    page.execute_script("window.scrollTo(0, document.body.scrollHeight)")
    expect(page.evaluate_script("window.scrollY")).to be > 0

    click_button "「しな11」をチェックする"

    expect(page).to have_button "「しな11」のチェックを外す"
    expect(page.evaluate_script("window.scrollY")).to be > 0
  end
end
