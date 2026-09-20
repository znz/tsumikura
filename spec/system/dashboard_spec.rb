require "rails_helper"

RSpec.describe "ダッシュボード", type: :system do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:user) { create(:user, name: "おかあさん") }

  it "アラートカードから該当する品目の一覧に飛べる" do
    urgent = create(:item, name: "ティッシュ", minimum_quantity: 5)
    create(:lot, item: urgent, initial_quantity: 3)
    create(:lot, item: create(:item, name: "ぜんぜんへらないもの"), initial_quantity: 100)

    sign_in_as user
    within("ul[aria-label='アラート']") { click_link "購入推奨" }

    expect(page).to have_current_path(items_path(purchase: "urgent"))
    within("ul[aria-label='品目一覧']") do
      expect(page).to have_text("ティッシュ")
      expect(page).to have_no_text("ぜんぜんへらないもの")
    end
  end

  it "期限切れのカードから期限切れの品目に飛べる" do
    item = create(:item, name: "レトルトカレー", tracks_expiry: true)
    create(:lot, item: item, initial_quantity: 2, expires_on: Date.current - 1)

    sign_in_as user
    within("ul[aria-label='アラート']") { click_link "期限切れ" }

    expect(page).to have_current_path(items_path(expiry: "expired"))
    within("ul[aria-label='品目一覧']") { expect(page).to have_text("レトルトカレー") }
  end

  # JS が無くてもワンタップ使用ができる (Turbo Stream ではなくリダイレクトで戻る)
  it "クイック使用のタイルから JS 無しで記録できる" do
    item = create(:item, :favorite, name: "トイレットペーパー", unit: "ロール")
    create(:lot, item: item, initial_quantity: 5)

    sign_in_as user
    within("ul[aria-label='クイック使用の品目']") { click_button "使った" }

    expect(page).to have_current_path(root_path)
    expect(page).to have_text("「トイレットペーパー」を 1 ロール 使いました。")
    expect(item.reload.current_quantity).to eq 4
  end

  it "最近の記録から品目詳細に行ける" do
    item = create(:item, name: "しょうゆ", unit: "本")
    create(:lot, item: item, initial_quantity: 3)

    sign_in_as user
    within("ul[aria-label='最近の記録一覧']") { click_link "しょうゆ" }

    expect(page).to have_current_path(item_path(item))
  end

  it "品目詳細に在庫切れ予測日とペースが出る" do
    item = create(:item, name: "トイレットペーパー", unit: "ロール")
    record_usages(item, interval: 5, times: 19, last_used_days_ago: 2)
    stock_up(item, 3)

    sign_in_as user
    visit item_path(item)

    within("section[aria-label='予測']") do
      expect(page).to have_text("そろそろ購入")
      expect(page).to have_text("あと 18 日")
      expect(page).to have_text("約 6.0 ロール / 月")
    end
  end
end
