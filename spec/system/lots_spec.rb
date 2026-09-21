require "rails_helper"

RSpec.describe "購入の記録", type: :system do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:user) { create(:user) }
  let(:item) { create(:item, name: "トイレットペーパー", unit: "ロール", default_pack_size: 12) }

  # 既定のドライバは rack_test (JS 無し)。JS が無くても購入を記録できることを確かめる
  describe "JS が無いとき" do
    it "品目詳細から購入を記録すると在庫が増える" do
      create(:store, name: "あおぞらスーパー")
      sign_in_as user

      visit item_path(item)
      click_link "購入を記録"

      fill_in "入数", with: "12"
      fill_in "パック数", with: "2"
      fill_in "金額 (税込)", with: "912"
      select "あおぞらスーパー", from: "店舗"
      click_button "記録する"

      expect(page).to have_text "記録しました"
      within("section[aria-label='在庫']") { expect(page).to have_text "24" }
      within("ul[aria-label='ロット一覧']") do
        expect(page).to have_text "残り 24 ロール"
        expect(page).to have_text "あおぞらスーパー"
        expect(page).to have_text "38円/ロール"
      end
    end

    # 切り替えボタンは Stimulus が付いたときだけ出す。JS が無いときは
    # 入数・パック数・数量をすべて出し、サーバ側で数量を決める
    it "切り替えボタンは出ず、数量の入力欄が 3 つとも出ている" do
      sign_in_as user

      visit new_item_lot_path(item)

      expect(page).to have_field("入数")
      expect(page).to have_field("パック数")
      expect(page).to have_field("数量")
      # 切り替えボタンはマークアップとしては在るが、JS が無いときは見えない
      expect(page).to have_css("input[name='quantity_mode']", visible: :all, count: 2)
      expect(page).to have_no_css("input[name='quantity_mode']")
    end

    it "入数とパック数を空にすると、直接入力の数量で記録できる" do
      sign_in_as user

      visit new_item_lot_path(item)
      fill_in "入数", with: ""
      fill_in "パック数", with: ""
      fill_in "数量", with: "5"
      click_button "記録する"

      expect(item.reload.current_quantity).to eq 5
    end

    it "初期在庫として記録できる" do
      sign_in_as user

      visit new_item_lot_path(item)
      choose "初期在庫"
      fill_in "入数", with: ""
      fill_in "パック数", with: ""
      fill_in "数量", with: "3"
      click_button "記録する"

      expect(Lot.order(:id).last).to be_kind_initial
      expect(item.reload.current_quantity).to eq 3
    end

    it "期限を管理する品目では期限日を入れられる" do
      expiring = create(:item, :tracks_expiry, name: "たまご", unit: "個")
      sign_in_as user

      visit new_item_lot_path(expiring)
      fill_in "数量", with: "10"
      fill_in "期限日", with: (Date.current + 7).to_s
      click_button "記録する"

      expect(Lot.order(:id).last.expires_on).to eq Date.current + 7
      within("ul[aria-label='ロット一覧']") { expect(page).to have_text I18n.l(Date.current + 7) }
    end

    it "期限を管理しない品目には期限日の欄が出ない" do
      sign_in_as user

      visit new_item_lot_path(item)

      expect(page).to have_no_field("期限日")
    end

    # rack_test は input の max 属性を見ないので、サーバ側の検証が効いていることが分かる
    it "未来の日付を送るとエラーを出してフォームに戻る" do
      sign_in_as user

      visit new_item_lot_path(item)
      fill_in "購入日", with: (Date.current + 1).to_s
      click_button "記録する"

      expect(page).to have_text "未来の日付は指定できません"
      expect(Lot.count).to eq 0
    end

    it "記録した購入を編集すると在庫が変わる" do
      create(:lot, item: item, initial_quantity: 12)
      sign_in_as user

      visit item_path(item)
      within("ul[aria-label='ロット一覧']") { click_link "編集" }
      fill_in "入数", with: ""
      fill_in "パック数", with: ""
      fill_in "数量", with: "6"
      click_button "保存"

      expect(page).to have_text "更新しました"
      within("section[aria-label='在庫']") { expect(page).to have_text "6" }
      expect(item.reload.current_quantity).to eq 6
    end

    it "記録した購入を削除すると在庫が戻る" do
      create(:lot, item: item, initial_quantity: 12)
      sign_in_as user

      visit item_path(item)
      within("ul[aria-label='ロット一覧']") { click_link "編集" }
      click_button "削除する"

      expect(page).to have_text "削除しました"
      expect(item.reload.current_quantity).to eq 0
      expect(page).to have_text "在庫のあるロットはまだありません"
    end
  end

  # 実ブラウザでは Stimulus が切り替えボタンを出し、使わない側の入力欄を送らない
  describe "実ブラウザ", js: true do
    it "「直接入力」に切り替えると入数とパック数が消え、数量だけで記録できる" do
      sign_in_as user

      visit new_item_lot_path(item)
      expect(page).to have_field("入数")

      choose "直接入力"

      expect(page).to have_no_field("入数", exact: true)
      fill_in "数量", with: "5"
      click_button "記録する"

      expect(page).to have_text "記録しました"
      expect(item.reload.current_quantity).to eq 5
    end

    it "「入数 × パック数」に切り替えると数量の欄が消え、掛け算で記録できる" do
      sign_in_as user

      visit new_item_lot_path(item)
      choose "直接入力"
      choose "入数 × パック数"

      expect(page).to have_no_field("数量", exact: true)
      fill_in "入数", with: "12"
      fill_in "パック数", with: "2"
      click_button "記録する"

      expect(page).to have_text "記録しました"
      expect(item.reload.current_quantity).to eq 24
    end
  end
end
