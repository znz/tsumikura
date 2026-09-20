require "rails_helper"

RSpec.describe "ダッシュボード", type: :request do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:user) { create(:user, name: "おかあさん") }

  before { sign_in user }

  describe "アラートカード" do
    it "購入推奨の品目数が出る" do
      urgent = create(:item, name: "ティッシュ", minimum_quantity: 5)
      create(:lot, item: urgent, initial_quantity: 3)

      get root_path

      expect(response).to have_http_status(:ok)
      expect(rendered_list("アラート")).to include "購入推奨"
      expect(response.parsed_body.at("a[href='#{items_path(purchase: 'urgent')}']").text)
        .to include "1"
    end

    it "そろそろ購入の品目数が出る" do
      # 5 日おきに使い続けていて在庫 3 → 残り 18 日 (検算例 1)
      item = create(:item, name: "トイレットペーパー")
      record_usages(item, interval: 5, times: 19, last_used_days_ago: 2)
      stock_up(item, 3)

      get root_path

      expect(response.parsed_body.at("a[href='#{items_path(purchase: 'soon')}']").text)
        .to include "1"
    end

    # データ不足の品目を「買え」と言わない (docs/spec/02-forecast.md 1 節)
    it "unknown の品目は要購入に数えない" do
      item = create(:item, name: "しょうゆ")
      stock_up(item, 5, days_ago: 60)
      record_usage(item, days_ago: 10)

      get root_path

      expect(Forecast::ItemForecaster.call(item.reload).status).to eq :unknown
      expect(response.parsed_body.at("a[href='#{items_path(purchase: 'urgent')}']")).to be_nil
      expect(response.parsed_body.at("a[href='#{items_path(purchase: 'soon')}']")).to be_nil
    end

    it "期限切れの品目数が出る" do
      item = create(:item, name: "レトルトカレー", tracks_expiry: true)
      create(:lot, item: item, initial_quantity: 2, expires_on: Date.current - 1)

      get root_path

      expect(response.parsed_body.at("a[href='#{items_path(expiry: 'expired')}']").text)
        .to include "1"
    end

    it "期限間近の品目数が出る" do
      item = create(:item, name: "ヨーグルト", tracks_expiry: true)
      create(:lot, item: item, initial_quantity: 2, expires_on: Date.current + 3)

      get root_path

      expect(response.parsed_body.at("a[href='#{items_path(expiry: 'expiring_soon')}']").text)
        .to include "1"
    end

    # 色だけに頼らず、リンクとして何件の何かが読める
    it "カードはリンクとして読める (件数と行き先が分かる)" do
      item = create(:item, name: "ティッシュ", minimum_quantity: 5)
      create(:lot, item: item, initial_quantity: 3)

      get root_path

      link = response.parsed_body.at("a[href='#{items_path(purchase: 'urgent')}']")
      expect(link["aria-label"]).to eq "購入推奨 1 件の品目を見る"
    end

    # 押しても 0 件の一覧が出るだけなので、リンクにはしない
    it "0 件のカードはリンクにしない" do
      get root_path

      expect(rendered_list("アラート")).to include "購入推奨"
      expect(response.parsed_body.at("a[href='#{items_path(purchase: 'urgent')}']")).to be_nil
    end

    it "アーカイブ済みの品目は数えない" do
      # 在庫 0 でペース不明なので、有効な品目ならこれだけで購入推奨になる
      archived = create(:item, :archived, name: "むかしの洗剤", minimum_quantity: 5)

      get root_path

      expect(Forecast::ItemForecaster.call(archived).status).to eq :urgent
      expect(response.parsed_body.at("a[href='#{items_path(purchase: 'urgent')}']")).to be_nil
      expect(response.parsed_body.at("a[href='#{items_path(expiry: 'expired')}']")).to be_nil
    end
  end

  describe "クイック使用" do
    it "お気に入りの品目がタイルに出て、ワンタップで記録できる" do
      item = create(:item, :favorite, name: "トイレットペーパー")
      create(:lot, item: item, initial_quantity: 5)

      get root_path

      expect(rendered_list("クイック使用の品目")).to include "トイレットペーパー"
      expect(response.parsed_body.at("form[action='#{item_quick_use_path(item)}']")).to be_present
    end

    it "最近使った品目もタイルに出る" do
      item = create(:item, name: "しょうゆ")
      stock_up(item, 5, days_ago: 30)
      record_usage(item, days_ago: 1)

      get root_path

      expect(rendered_list("クイック使用の品目")).to include "しょうゆ"
    end

    it "使ったこともお気に入りでもない品目はタイルに出ない" do
      create(:item, name: "ぼうさいようひん")

      get root_path

      expect(rendered_list("クイック使用の品目")).not_to include "ぼうさいようひん"
    end

    # ワンタップだと用途が付かないので、用途を管理する品目はフォームへ送る
    it "用途を管理する品目は用途を選べるフォームへのリンクになる" do
      item = create(:item, :favorite, name: "単 3 電池", tracks_purposes: true)
      create(:lot, item: item, initial_quantity: 5)

      get root_path

      expect(response.parsed_body.at("form[action='#{item_quick_use_path(item)}']")).to be_nil
      expect(response.parsed_body.at("a[href='#{new_item_usage_record_path(item)}']")).to be_present
    end

    it "アーカイブ済みの品目はタイルに出ない" do
      create(:item, :archived, :favorite, name: "むかしの洗剤")

      get root_path

      expect(rendered_list("クイック使用の品目")).not_to include "むかしの洗剤"
    end

    it "件数が多すぎるときは決まった数だけ出す" do
      stub_const("DashboardSummary::QUICK_USE_LIMIT", 1)
      create(:item, :favorite, name: "あいすくりーむ")
      create(:item, :favorite, name: "ばななみるく")

      get root_path

      expect(rendered_list("クイック使用の品目")).to include "あいすくりーむ"
      expect(rendered_list("クイック使用の品目")).not_to include "ばななみるく"
    end
  end

  describe "最近の記録" do
    it "全品目を横断して新しい順に並び、品目名が出る" do
      soy = create(:item, name: "しょうゆ", unit: "本")
      paper = create(:item, name: "トイレットペーパー", unit: "ロール")
      create(:lot, item: paper, initial_quantity: 12, acquired_on: Date.current - 3)
      stock_up(soy, 5, days_ago: 30)
      record_usage(soy, days_ago: 0, quantity: 2)

      get root_path

      records = rendered_list("最近の記録一覧")
      expect(records).to include "しょうゆ"
      expect(records).to include "トイレットペーパー"
      expect(records).to include "使った 2 本"
      expect(records).to include "購入 12 ロール"
      expect(records.index("しょうゆ")).to be < records.index("トイレットペーパー")
    end

    it "決まった件数だけ出す" do
      stub_const("DashboardSummary::RECENT_RECORDS_LIMIT", 1)
      item = create(:item, name: "しょうゆ", unit: "本")
      stock_up(item, 50, days_ago: 30)
      record_usage(item, days_ago: 3, quantity: 1)
      record_usage(item, days_ago: 0, quantity: 7)

      get root_path

      expect(rendered_list("最近の記録一覧")).to include "使った 7 本"
      expect(rendered_list("最近の記録一覧")).not_to include "使った 1 本"
    end

    it "アーカイブ済みの品目の記録は出さない" do
      item = create(:item, :archived, name: "むかしの洗剤", unit: "本")
      create(:lot, item: item, initial_quantity: 3)

      get root_path

      expect(rendered_list("最近の記録一覧")).not_to include "むかしの洗剤"
    end

    it "記録が無ければその旨を出す" do
      get root_path

      expect(response.parsed_body.at("section[aria-label='最近の記録']").text)
        .to include "まだ記録がありません"
    end
  end

  # ダッシュボードから押したワンタップ使用は、タイルだけでなくアラートカードと
  # 最近の記録も描き直す (タイルが購入推奨に変わったのにカードが 0 件のまま、を防ぐ)
  describe "ダッシュボードからのワンタップ使用" do
    let(:turbo_headers) { { "Accept" => "text/vnd.turbo-stream.html" } }

    it "タイルの「使った」は押した画面がダッシュボードであることを送る" do
      item = create(:item, :favorite, name: "トイレットペーパー")
      create(:lot, item: item, initial_quantity: 5)

      get root_path

      form = response.parsed_body.at("form[action='#{item_quick_use_path(item)}']")
      expect(form.at("input[name='from']")[:value]).to eq "dashboard"
    end

    it "アラートカードと最近の記録も差し替える" do
      item = create(:item, :favorite, name: "トイレットペーパー", minimum_quantity: 5)
      create(:lot, item: item, initial_quantity: 5)

      post item_quick_use_path(item), params: { from: "dashboard" }, headers: turbo_headers

      expect(response.body).to include %(target="alerts")
      expect(response.body).to include %(target="recent_records")
      # 在庫 4 < 最低在庫 5 になったので、カードの件数も 1 件に変わる
      alerts = Nokogiri::HTML4::DocumentFragment.parse(response.body).at("ul#alerts")
      expect(alerts.at("a[href='#{items_path(purchase: 'urgent')}']").text).to include "1"
      # ダッシュボードの「最近の記録」は品目名つき (品目詳細のほうは品目名を出さない)
      recent = Nokogiri::HTML4::DocumentFragment.parse(response.body).at("section#recent_records")
      expect(recent.text).to include "トイレットペーパー"
      expect(recent.text).to include "使った 1"
    end

    it "品目一覧から押したときはカードを差し替えない" do
      item = create(:item, name: "トイレットペーパー")
      create(:lot, item: item, initial_quantity: 5)

      post item_quick_use_path(item), headers: turbo_headers

      expect(response.body).to include %(target="item_#{item.id}")
      expect(response.body).not_to include %(target="alerts")
      expect(response.body).not_to include %(target="recent_records")
    end
  end

  describe "クエリ数" do
    it "品目と記録が増えてもクエリ数は増えない" do
      # 店舗が 1 件だと 2 本目の読み込みがクエリキャッシュに当たるので、基準は 2 件から
      2.times do
        item = create(:item, :favorite)
        create(:lot, item: item, initial_quantity: 10, store: create(:store))
        record_usage(item, days_ago: 1)
      end
      get root_path # ウォームアップ

      baseline = count_queries { get root_path }
      3.times do
        item = create(:item, :favorite)
        create(:lot, item: item, initial_quantity: 10, store: create(:store))
        record_usage(item, days_ago: 1)
      end

      expect(count_queries { get root_path }).to eq baseline
    end
  end
end
