require "rails_helper"

RSpec.describe "使用の記録", type: :system do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:user) { create(:user) }
  let(:item) { create(:item, name: "トイレットペーパー", unit: "ロール") }

  def row_for(item)
    "li##{ActionView::RecordIdentifier.dom_id(item)}"
  end

  # 既定のドライバは rack_test (JS 無し)。JS が無くてもワンタップ使用と取り消しが動く
  describe "JS が無いとき" do
    it "品目一覧の「使った」で在庫が 1 減り、取り消しで戻る" do
      create(:lot, item: item, initial_quantity: 5)
      sign_in_as user

      visit items_path
      within(row_for(item)) { click_button "使った" }

      expect(page).to have_text "使いました"
      within(row_for(item)) { expect(page).to have_text "4" }

      click_button "取り消し"

      expect(page).to have_text "取り消しました"
      within(row_for(item)) { expect(page).to have_text "5" }
      expect(item.reload.current_quantity).to eq 5
    end

    it "在庫が足りなくてもワンタップの記録は成功し、調整したことを伝える" do
      item # let は遅延評価なので、一覧を開く前に作っておく (在庫 0 のまま)
      sign_in_as user

      visit items_path
      within(row_for(item)) { click_button "使った" }

      expect(page).to have_text "在庫記録が不足していたため 1 ロール を調整しました"
      expect(item.reload.current_quantity).to eq 0
    end

    it "用途を管理する品目の「使った」は用途を選べるフォームに行く" do
      purposes_item = create(:item, name: "単 3 電池", unit: "本", tracks_purposes: true)
      create(:item_purpose, item: purposes_item, name: "リモコン")
      create(:lot, item: purposes_item, initial_quantity: 4)
      sign_in_as user

      visit items_path
      within(row_for(purposes_item)) { click_link "使った" }

      expect(page).to have_text "使用を記録"
      choose "リモコン"
      fill_in "数量", with: "2"
      click_button "記録する"

      expect(page).to have_text "使いました"
      expect(UsageRecord.sole.item_purpose.name).to eq "リモコン"
      expect(purposes_item.reload.current_quantity).to eq 2
    end

    it "品目詳細から数量と日付を指定して記録できる" do
      create(:lot, item: item, initial_quantity: 10)
      sign_in_as user

      visit item_path(item)
      click_link "使用を記録"

      fill_in "数量", with: "3"
      fill_in "使用日", with: (Date.current - 1).to_s
      fill_in "メモ", with: "来客用"
      click_button "記録する"

      expect(page).to have_text "使いました"
      within("section[aria-label='在庫']") { expect(page).to have_text "7" }
      expect(UsageRecord.sole.used_on).to eq Date.current - 1
    end

    # rack_test は input の max 属性を見ないので、サーバ側の検証が効いていることが分かる
    it "未来の日付はサーバ側で弾かれ、フォームに戻る" do
      create(:lot, item: item, initial_quantity: 10)
      sign_in_as user

      visit new_item_usage_record_path(item)
      fill_in "使用日", with: (Date.current + 1).to_s
      click_button "記録する"

      expect(page).to have_text "未来の日付は指定できません"
      expect(UsageRecord.count).to eq 0
    end

    it "期限を管理する品目ではロットを選べる" do
      expiring = create(:item, :tracks_expiry, name: "たまご", unit: "個")
      near = create(:lot, item: expiring, initial_quantity: 6, expires_on: Date.current + 2)
      far = create(:lot, item: expiring, initial_quantity: 6, expires_on: Date.current + 30)
      sign_in_as user

      visit new_item_usage_record_path(expiring)
      select lot_option_label_for(far, expiring), from: "ロット"
      fill_in "数量", with: "2"
      click_button "記録する"

      expect(far.reload.remaining_quantity).to eq 4
      expect(near.reload.remaining_quantity).to eq 6
    end

    it "記録した使用を編集すると在庫が追随する" do
      create(:lot, item: item, initial_quantity: 10)
      create(:usage_record, item: item, user: user, quantity: 3)
      sign_in_as user

      visit item_path(item)
      # 最近の記録には購入の行も並ぶので、使用の行に絞る
      within("ul[aria-label='最近の記録一覧'] li", text: "使った") { click_link "編集" }
      fill_in "数量", with: "5"
      click_button "保存"

      expect(page).to have_text "更新しました"
      within("section[aria-label='在庫']") { expect(page).to have_text "5" }
    end

    it "最近の記録から削除すると在庫が戻る" do
      create(:lot, item: item, initial_quantity: 10)
      create(:usage_record, item: item, user: user, quantity: 3)
      sign_in_as user

      visit item_path(item)
      within("ul[aria-label='最近の記録一覧'] li", text: "使った") { click_button "削除" }

      expect(page).to have_text "取り消しました"
      within("section[aria-label='在庫']") { expect(page).to have_text "10" }
    end

    # +/− は Stimulus が付いたときだけ現れる。JS が無くても数値入力だけで記録できる
    it "JS が無いときは数量の +/− ボタンを出さない" do
      sign_in_as user

      visit new_item_usage_record_path(item)

      expect(page).to have_field("数量")
      expect(page).to have_css("button[aria-label='数量を 1 増やす']", visible: :all)
      expect(page).to have_no_css("button[aria-label='数量を 1 増やす']")
    end

    it "JS が無いときは日付の「今日 / 昨日」ボタンを出さない" do
      sign_in_as user

      visit new_item_usage_record_path(item)

      expect(page).to have_field("使用日")
      expect(page).to have_no_button("昨日")
    end
  end

  describe "用途の管理" do
    let(:item) { create(:item, name: "単 3 電池", unit: "本", tracks_purposes: true) }

    it "品目詳細から用途を追加・並べ替え・アーカイブできる" do
      sign_in_as user

      visit item_path(item)
      click_link "用途を管理"

      click_link "用途を追加"
      fill_in "名前", with: "リモコン"
      fill_in "既定の数量", with: "2"
      click_button "追加する"
      expect(page).to have_text "追加しました"

      click_link "用途を追加"
      fill_in "名前", with: "時計"
      click_button "追加する"

      within("ul[aria-label='用途一覧'] li", text: "時計") { click_button "上へ" }
      expect(item.item_purposes.ordered.pluck(:name)).to eq [ "時計", "リモコン" ]

      within("ul[aria-label='用途一覧'] li", text: "リモコン") { click_button "アーカイブ" }
      expect(page).to have_text "アーカイブしました"
      within("ul[aria-label='用途一覧']") { expect(page).to have_no_text "リモコン" }
    end

    it "使用の記録がある用途は削除できない" do
      purpose = create(:item_purpose, item: item, name: "リモコン")
      create(:usage_record, item: item, item_purpose: purpose)
      sign_in_as user

      visit edit_item_purpose_path(item, purpose)

      expect(page).to have_text "削除できません"
      expect(page).to have_button("削除する", disabled: true)
    end
  end

  # 実ブラウザでは Turbo Stream で行と在庫が差し替わり、トーストが 8 秒で消える
  describe "実ブラウザ", js: true do
    it "ワンタップで行の在庫が変わり、トーストの取り消しで戻せる" do
      create(:lot, item: item, initial_quantity: 5)
      sign_in_as user

      visit items_path
      within(row_for(item)) { click_button "使った" }

      within("#toasts") { expect(page).to have_text "使いました" }
      within(row_for(item)) { expect(page).to have_text "4" }

      within("#toasts") { click_button "取り消し" }

      expect(page).to have_text "取り消しました"
      within(row_for(item)) { expect(page).to have_text "5" }
    end

    it "トーストは 8 秒で自動的に消える" do
      create(:lot, item: item, initial_quantity: 5)
      sign_in_as user

      visit items_path
      within(row_for(item)) { click_button "使った" }

      within("#toasts") { expect(page).to have_text "使いました" }
      expect(page).to have_no_css("#toasts [role='status']", wait: 12)
    end

    it "数量の +/− ボタンで数量を変えられる" do
      create(:lot, item: item, initial_quantity: 10)
      sign_in_as user

      visit new_item_usage_record_path(item)
      2.times { find("button[aria-label='数量を 1 増やす']").click }
      click_button "記録する"

      expect(page).to have_text "使いました"
      expect(UsageRecord.sole.quantity).to eq 3
    end

    it "用途を選ぶと数量がその用途の既定になる" do
      purposes_item = create(:item, name: "単 3 電池", unit: "本", tracks_purposes: true)
      create(:item_purpose, item: purposes_item, name: "リモコン", default_quantity: 2)
      create(:lot, item: purposes_item, initial_quantity: 10)
      sign_in_as user

      visit new_item_usage_record_path(purposes_item)
      choose "リモコン"

      expect(page).to have_field("数量", with: "2")
    end

    it "「昨日」ボタンで使用日を前日にできる" do
      create(:lot, item: item, initial_quantity: 10)
      sign_in_as user

      visit new_item_usage_record_path(item)
      click_button "昨日"
      click_button "記録する"

      expect(page).to have_text "使いました"
      expect(UsageRecord.sole.used_on).to eq Date.current - 1
    end
  end

  # ビューと同じ文言でロットの選択肢を組み立てる (ApplicationHelper#lot_option_label)
  def lot_option_label_for(lot, item)
    expiry = lot.expires_on ? "期限 #{I18n.l(lot.expires_on)}" : "期限なし"

    "#{expiry} ・ 残り #{lot.remaining_quantity} #{item.unit} (#{I18n.l(lot.acquired_on)} 購入)"
  end
end
