require "rails_helper"

RSpec.describe "品目", type: :request do
  let(:user) { create(:user) }

  describe "GET /items (一覧)" do
    before { sign_in user }

    it "有効な品目が並ぶ" do
      item = create(:item, name: "トイレットペーパー")

      get items_path

      expect(response).to have_http_status(:ok)
      expect(rendered_list("品目一覧")).to include item.name
    end

    it "アーカイブ済みの品目は既定では出ない" do
      active = create(:item, name: "ティッシュ")
      archived = create(:item, :archived, name: "むかしの洗剤")

      get items_path

      expect(rendered_list("品目一覧")).to include active.name
      expect(rendered_list("品目一覧")).not_to include archived.name
    end

    it "状態を archived にするとアーカイブ済みだけが出る" do
      active = create(:item, name: "ティッシュ")
      archived = create(:item, :archived, name: "むかしの洗剤")

      get items_path, params: { status: "archived" }

      expect(rendered_list("品目一覧")).to include archived.name
      expect(rendered_list("品目一覧")).not_to include active.name
    end

    it "状態を all にすると両方出る" do
      active = create(:item, name: "ティッシュ")
      archived = create(:item, :archived, name: "むかしの洗剤")

      get items_path, params: { status: "all" }

      expect(rendered_list("品目一覧")).to include active.name
      expect(rendered_list("品目一覧")).to include archived.name
    end

    it "知らない状態が来ても有効な品目だけを出す" do
      active = create(:item, name: "ティッシュ")
      archived = create(:item, :archived, name: "むかしの洗剤")

      get items_path, params: { status: "everything" }

      expect(rendered_list("品目一覧")).to include active.name
      expect(rendered_list("品目一覧")).not_to include archived.name
    end

    it "カテゴリで絞り込める" do
      kitchen = create(:category, name: "キッチン")
      bath = create(:category, name: "おふろ")
      hit = create(:item, name: "ラップ", category: kitchen)
      miss = create(:item, name: "シャンプー", category: bath)

      get items_path, params: { category_id: kitchen.id }

      # カテゴリ名は絞り込みセレクトの option にも出るので、必ず品目名で確かめる
      expect(rendered_list("品目一覧")).to include hit.name
      expect(rendered_list("品目一覧")).not_to include miss.name
    end

    it "保管場所で絞り込める" do
      pantry = create(:storage_location, name: "パントリー")
      washroom = create(:storage_location, name: "洗面所")
      hit = create(:item, name: "パスタ", storage_location: pantry)
      miss = create(:item, name: "歯ブラシ", storage_location: washroom)

      get items_path, params: { storage_location_id: pantry.id }

      expect(rendered_list("品目一覧")).to include hit.name
      expect(rendered_list("品目一覧")).not_to include miss.name
    end

    it "名前で検索できる" do
      hit = create(:item, name: "トイレットペーパー")
      miss = create(:item, name: "キッチンペーパー")

      get items_path, params: { q: "トイレット" }

      expect(rendered_list("品目一覧")).to include hit.name
      expect(rendered_list("品目一覧")).not_to include miss.name
    end

    it "よみで検索できる" do
      hit = create(:item, name: "食器用洗剤", name_reading: "しょっきようせんざい")
      miss = create(:item, name: "柔軟剤", name_reading: "じゅうなんざい")

      get items_path, params: { q: "しょっき" }

      expect(rendered_list("品目一覧")).to include hit.name
      expect(rendered_list("品目一覧")).not_to include miss.name
    end

    it "検索とカテゴリ絞り込みは同時に効く" do
      kitchen = create(:category, name: "キッチン")
      bath = create(:category, name: "おふろ")
      hit = create(:item, name: "キッチンペーパー", category: kitchen)
      same_name_other_category = create(:item, name: "キッチンタイマー", category: bath)
      same_category_other_name = create(:item, name: "ラップ", category: kitchen)

      get items_path, params: { q: "キッチン", category_id: kitchen.id }

      expect(rendered_list("品目一覧")).to include hit.name
      expect(rendered_list("品目一覧")).not_to include same_name_other_category.name
      expect(rendered_list("品目一覧")).not_to include same_category_other_name.name
    end

    it "1 件も当たらないときはその旨を出す" do
      create(:item, name: "ティッシュ")

      get items_path, params: { q: "ぜったいにない" }

      expect(rendered_list("品目一覧")).not_to include "ティッシュ"
      expect(response.body).to include "見つかりません"
    end

    # 壊れた値で 0 件になると「品目が無い」ように見えてしまうので、無視して既定に倒す
    it "壊れた絞り込みパラメータ (配列・ハッシュ) は無視される" do
      item = create(:item, name: "ティッシュ")

      get items_path, params: { q: [ "x" ], category_id: { a: "b" },
                                storage_location_id: [ "1" ], status: [ "all" ] }

      expect(response).to have_http_status(:ok)
      expect(rendered_list("品目一覧")).to include item.name
    end

    it "数字でないカテゴリ id は無視される" do
      item = create(:item, name: "ティッシュ", category: create(:category))

      get items_path, params: { category_id: "abc" }

      expect(response).to have_http_status(:ok)
      expect(rendered_list("品目一覧")).to include item.name
    end

    it "存在しないカテゴリ id を指定したときは 0 件になる (絞り込みは効いている)" do
      create(:item, name: "ティッシュ", category: create(:category))

      get items_path, params: { category_id: Category.maximum(:id) + 1 }

      expect(rendered_list("品目一覧")).not_to include "ティッシュ"
    end

    it "品目が増えてもクエリ数は増えない (カテゴリと保管場所を includes している)" do
      create(:item, category: create(:category), storage_location: create(:storage_location))
      get items_path # ウォームアップ (初回のスキーマ読み込みなどを数えない)

      baseline = count_queries { get items_path }
      3.times { create(:item, category: create(:category), storage_location: create(:storage_location)) }

      expect(count_queries { get items_path }).to eq baseline
    end
  end

  describe "GET /items/:id (詳細)" do
    before { sign_in user }

    it "在庫数と単位・分類・設定値が表示される" do
      item = create(:item, name: "トイレットペーパー", unit: "ロール",
        minimum_quantity: 4, default_pack_size: 12,
        estimation_mode: :manual, manual_interval_days: 45,
        soon_threshold_days: 30, urgent_threshold_days: 10,
        tracks_expiry: true, expiry_warning_days: 14, tracks_purposes: true,
        category: create(:category, name: "日用品"),
        storage_location: create(:storage_location, name: "洗面所"))

      get item_path(item)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include "トイレットペーパー"
      expect(response.body).to include "日用品"
      expect(response.body).to include "洗面所"

      stock = response.parsed_body.at("section[aria-label='在庫']").text
      expect(stock).to include "0"
      expect(stock).to include "ロール"
      expect(stock).to include "最低在庫数: 4"

      settings = response.parsed_body.at("section[aria-label='設定']").text
      expect(settings).to include "12 ロール"       # 入数の既定値
      expect(settings).to include "手動"            # 予測モード
      expect(settings).to include "45 日"           # 使用間隔
      expect(settings).to include "残り 30 日"      # そろそろ購入
      expect(settings).to include "残り 10 日"      # 購入推奨
      expect(settings).to include "14 日前から警告" # 期限警告日数
    end

    it "アーカイブ済みの品目でも詳細は開ける" do
      item = create(:item, :archived, name: "むかしの洗剤")

      get item_path(item)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include item.name
    end

    it "存在しない品目は 404" do
      get item_path(id: 0)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /items (作成)" do
    before { sign_in user }

    it "品目を作成できる" do
      category = create(:category)

      expect {
        post items_path, params: { item: { name: "トイレットペーパー", name_reading: "といれっとぺーぱー",
                                           unit: "ロール", category_id: category.id } }
      }.to change { Item.count }.by(1)

      item = Item.order(:id).last
      expect(item.name).to eq "トイレットペーパー"
      expect(item.unit).to eq "ロール"
      expect(item.category).to eq category
      expect(response).to redirect_to item_path(item)
    end

    it "作成直後の在庫数は 0" do
      post items_path, params: { item: { name: "ティッシュ", unit: "箱" } }

      expect(Item.order(:id).last.current_quantity).to eq 0
    end

    it "名前が空なら作成できず、フォームを再表示する" do
      expect {
        post items_path, params: { item: { name: "", unit: "個" } }
      }.not_to change { Item.count }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include "名前"
    end

    it "キャッシュ列とアーカイブはフォームから設定できない" do
      post items_path, params: { item: { name: "ティッシュ", unit: "箱", current_quantity: 99,
                                         tracking_started_on: "2026-01-01", last_consumed_on: "2026-01-02",
                                         archived_at: 1.day.ago.iso8601 } }

      item = Item.order(:id).last
      expect(item.current_quantity).to eq 0
      expect(item.tracking_started_on).to be_nil
      expect(item.last_consumed_on).to be_nil
      expect(item.archived_at).to be_nil
    end

    it "4 バイト整数をはみ出す数量を送っても 500 にならず 422 になる" do
      expect {
        post items_path, params: { item: { name: "ティッシュ", unit: "箱",
                                           default_pack_size: "99999999999" } }
      }.not_to change { Item.count }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "削除済みのカテゴリ id を送っても 500 にならず 422 になる" do
      category = create(:category)
      category_id = category.id
      category.destroy

      expect {
        post items_path, params: { item: { name: "ティッシュ", unit: "箱", category_id: category_id } }
      }.not_to change { Item.count }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "item キーが無ければ 400 (500 にしない)" do
      post items_path, params: { name: "ティッシュ" }

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "PATCH /items/:id (更新)" do
    before { sign_in user }

    it "品目を更新できる" do
      item = create(:item, name: "旧名", unit: "個")

      patch item_path(item), params: { item: { name: "新名", unit: "本" } }

      expect(item.reload.name).to eq "新名"
      expect(item.unit).to eq "本"
      expect(response).to redirect_to item_path(item)
    end

    it "予測設定を更新できる" do
      item = create(:item)

      patch item_path(item), params: { item: { name: item.name, unit: item.unit,
                                               estimation_mode: "manual", manual_interval_days: "45",
                                               soon_threshold_days: "30", urgent_threshold_days: "10",
                                               expiry_warning_days: "14", tracks_expiry: "1",
                                               tracks_purposes: "1", favorite: "1", minimum_quantity: "2" } }

      item.reload
      expect(item.estimation_mode).to eq "manual"
      expect(item.manual_interval_days).to eq 45
      expect(item.soon_threshold_days).to eq 30
      expect(item.urgent_threshold_days).to eq 10
      expect(item.expiry_warning_days).to eq 14
      expect(item.minimum_quantity).to eq 2
      expect(item).to be_tracks_expiry
      expect(item).to be_tracks_purposes
      expect(item).to be_favorite
    end

    it "予測モードを手動にして使用間隔が空なら更新できない" do
      item = create(:item)

      patch item_path(item), params: { item: { name: item.name, unit: item.unit,
                                               estimation_mode: "manual", manual_interval_days: "" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(item.reload.estimation_mode).to eq "auto"
    end

    it "manual_interval_days が 0 なら更新できない" do
      item = create(:item)

      patch item_path(item), params: { item: { name: item.name, unit: item.unit,
                                               estimation_mode: "manual", manual_interval_days: "0" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(item.reload.manual_interval_days).to be_nil
    end

    it "購入推奨の日数がそろそろ購入の日数より大きいと更新できない" do
      item = create(:item)

      patch item_path(item), params: { item: { name: item.name, unit: item.unit,
                                               soon_threshold_days: "10", urgent_threshold_days: "20" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(item.reload.urgent_threshold_days).to be_nil
    end

    it "キャッシュ列とアーカイブはフォームから変更できない" do
      item = create(:item)

      patch item_path(item), params: { item: { name: "新名", unit: "個", current_quantity: 99,
                                               tracking_started_on: "2026-01-01", last_consumed_on: "2026-01-02",
                                               archived_at: 1.day.ago.iso8601 } }

      item.reload
      expect(item.name).to eq "新名" # 更新自体は成功している (無視されたのはキャッシュ列だけ)
      expect(item.current_quantity).to eq 0
      expect(item.tracking_started_on).to be_nil
      expect(item.last_consumed_on).to be_nil
      expect(item.archived_at).to be_nil
    end
  end

  describe "品目は削除できない" do
    before { sign_in user }

    it "DELETE /items/:id というルートを持たない" do
      expect {
        Rails.application.routes.recognize_path("/items/1", method: :delete)
      }.to raise_error(ActionController::RoutingError)
    end
  end
end
