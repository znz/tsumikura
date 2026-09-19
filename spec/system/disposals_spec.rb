require "rails_helper"

RSpec.describe "廃棄", type: :system do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:user) { create(:user) }
  let(:item) { create(:item, :tracks_expiry, name: "たまご", unit: "個") }

  # 既定のドライバは rack_test (JS 無し)。JS が無くても廃棄と取り消しができる
  describe "JS が無いとき" do
    it "品目詳細から廃棄でき、在庫が減る" do
      create(:lot, item: item, initial_quantity: 5)
      sign_in_as user

      visit item_path(item)
      click_link "廃棄を記録"

      fill_in "数量", with: "2"
      choose "破損"
      click_button "廃棄を記録する"

      expect(page).to have_text "2 個 廃棄しました"
      expect(item.reload.current_quantity).to eq 3
    end

    it "トーストの「取り消し」で在庫が戻る" do
      create(:lot, item: item, initial_quantity: 5)
      sign_in_as user

      visit new_item_disposal_path(item)
      fill_in "数量", with: "2"
      click_button "廃棄を記録する"
      # 品目詳細の「最近の記録」にも取り消しが並ぶので、トーストの中に絞る
      within("#toasts") { click_button "取り消し" }

      expect(page).to have_text "廃棄の記録を取り消しました"
      expect(item.reload.current_quantity).to eq 5
    end

    it "期限切れのロットから廃棄に進める" do
      expired = create(:lot, item: item, initial_quantity: 2, expires_on: Date.current - 1)
      create(:lot, item: item, initial_quantity: 5, expires_on: Date.current + 30)
      sign_in_as user

      visit item_path(item)
      within("ul[aria-label='ロット一覧']") { first("a[aria-label='このロットを廃棄']").click }

      fill_in "数量", with: "2"
      click_button "廃棄を記録する"

      expect(expired.reload.remaining_quantity).to eq 0
      expect(item.reload.current_quantity).to eq 5
    end

    it "在庫を超える廃棄はサーバ側で弾かれ、フォームに戻る" do
      create(:lot, item: item, initial_quantity: 1)
      sign_in_as user

      visit new_item_disposal_path(item)
      fill_in "数量", with: "5"
      click_button "廃棄を記録する"

      expect(page).to have_text "より多くできません"
      expect(item.reload.current_quantity).to eq 1
    end

    # ロット別の入力と同じく、details は JS 無しでも開ける
    it "最近の記録から廃棄を取り消せる" do
      create(:lot, item: item, initial_quantity: 5)
      sign_in_as user

      visit new_item_disposal_path(item)
      fill_in "数量", with: "2"
      click_button "廃棄を記録する"
      visit item_path(item)

      within("ul[aria-label='最近の記録一覧']") { click_button "取り消し" }

      expect(item.reload.current_quantity).to eq 5
    end
  end

  # トーストの自動消去だけが JS 必須 (toast_controller.js)。
  # ローカルには Chrome が無く skip されるので、CI で初めて実行される
  describe "実ブラウザ", js: true do
    it "廃棄のトーストから取り消せて、在庫が戻る" do
      create(:lot, item: item, initial_quantity: 5)
      sign_in_as user

      visit new_item_disposal_path(item)
      fill_in "数量", with: "2"
      click_button "廃棄を記録する"

      within("#toasts") { expect(page).to have_text "廃棄しました" }
      within("#toasts") { click_button "取り消し" }

      expect(page).to have_text "廃棄の記録を取り消しました"
      expect(item.reload.current_quantity).to eq 5
    end
  end
end
