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

    # 1 タップで在庫を減らせることが最優先の UX 目標 (docs/spec/00-overview.md 2 節)
    it "各行にワンタップの「使った」ボタンが出る" do
      item = create(:item, name: "トイレットペーパー")

      get items_path

      expect(response.parsed_body.at("form[action='#{item_quick_use_path(item)}']")).to be_present
      expect(response.parsed_body.at("li##{ActionView::RecordIdentifier.dom_id(item)}")).to be_present
    end

    # アーカイブ済みは日々使う品目ではないので、一覧から導線を出さない
    it "アーカイブ済みの品目には「使った」ボタンを出さない" do
      item = create(:item, :archived, name: "むかしの洗剤")

      get items_path(status: "archived")

      expect(rendered_list("品目一覧")).to include "むかしの洗剤"
      expect(response.parsed_body.at("form[action='#{item_quick_use_path(item)}']")).to be_nil
    end

    # 用途を管理する品目はワンタップだと用途が付かないので、フォームへ誘導する
    it "用途を管理する品目の「使った」は用途を選べるフォームへのリンクになる" do
      item = create(:item, name: "単 3 電池", tracks_purposes: true)

      get items_path

      expect(response.parsed_body.at("form[action='#{item_quick_use_path(item)}']")).to be_nil
      expect(response.parsed_body.at("a[href='#{new_item_usage_record_path(item)}']")).to be_present
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

    it "在庫数が出る (キャッシュ列なので集計しない)" do
      item = create(:item, name: "ティッシュ", unit: "箱")
      create(:lot, item: item, initial_quantity: 37)

      get items_path

      expect(rendered_list("品目一覧")).to include "ティッシュ"
      expect(rendered_list("品目一覧")).to include "37"
    end

    it "在庫のある品目が増えてもクエリ数は増えない (在庫数はキャッシュ列)" do
      create(:lot, item: create(:item), initial_quantity: 3)
      get items_path # ウォームアップ

      baseline = count_queries { get items_path }
      3.times { create(:lot, item: create(:item), initial_quantity: 3) }

      expect(count_queries { get items_path }).to eq baseline
    end

    it "品目が増えてもクエリ数は増えない (カテゴリと保管場所を includes している)" do
      create(:item, category: create(:category), storage_location: create(:storage_location))
      get items_path # ウォームアップ (初回のスキーマ読み込みなどを数えない)

      baseline = count_queries { get items_path }
      3.times { create(:item, category: create(:category), storage_location: create(:storage_location)) }

      expect(count_queries { get items_path }).to eq baseline
    end

    describe "ステータスバッジ" do
      # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
      before { freeze_time }

      # 色だけに頼らず文言を出す (docs/spec/03-screens.md ステータスの見せ方)
      it "最低在庫を下回る品目には「購入推奨」のバッジが出る" do
        item = create(:item, name: "ティッシュ", minimum_quantity: 5)
        create(:lot, item: item, initial_quantity: 3)

        get items_path

        expect(rendered_list("品目一覧")).to include "購入推奨"
      end

      it "期限切れのロットを持つ品目には「期限切れ」のバッジが出る" do
        item = create(:item, name: "レトルトカレー", tracks_expiry: true)
        create(:lot, item: item, initial_quantity: 2, expires_on: Date.current - 1)

        get items_path

        expect(rendered_list("品目一覧")).to include "期限切れ"
      end

      it "購入不要の品目にはバッジを出さない" do
        item = create(:item, name: "トイレットペーパー")
        record_usages(item, interval: 5, times: 19)
        stock_up(item, 200)

        get items_path

        expect(Forecast::ItemForecaster.call(item.reload).status).to eq :ok
        expect(rendered_list("品目一覧")).not_to include "購入不要"
        expect(rendered_list("品目一覧")).not_to include "購入推奨"
      end

      # データ不足は「—」。読み上げ用に理由を添える
      it "データ不足の品目は「—」で、読み上げ用の説明が付く" do
        item = create(:item, name: "しょうゆ")
        stock_up(item, 5, days_ago: 60)
        record_usage(item, days_ago: 10)

        get items_path

        expect(Forecast::ItemForecaster.call(item.reload).status).to eq :unknown
        expect(rendered_list("品目一覧")).to include "—"
        expect(rendered_list("品目一覧")).to include "予測できるデータがまだありません"
      end

      it "アーカイブ済みの品目にはバッジを出さない (予測しない)" do
        create(:item, :archived, name: "むかしの洗剤", minimum_quantity: 5)

        get items_path, params: { status: "archived" }

        expect(rendered_list("品目一覧")).to include "むかしの洗剤"
        expect(rendered_list("品目一覧")).not_to include "購入推奨"
      end

      # 期限のバッジも要購入と対称に落とす (片方だけ出るとねじれる)
      it "アーカイブ済みの品目には期限のバッジも出さない" do
        item = create(:item, :archived, name: "むかしのレトルト", tracks_expiry: true)
        create(:lot, item: item, initial_quantity: 2, expires_on: Date.current - 1)

        get items_path, params: { status: "archived" }

        expect(rendered_list("品目一覧")).to include "むかしのレトルト"
        expect(rendered_list("品目一覧")).not_to include "期限切れ"
      end
    end

    describe "アラートからの絞り込み" do
      before { freeze_time }

      let!(:urgent) do
        item = create(:item, name: "ティッシュ", minimum_quantity: 5)
        create(:lot, item: item, initial_quantity: 3)
        item
      end
      let!(:soon) do
        item = create(:item, name: "トイレットペーパー")
        record_usages(item, interval: 5, times: 19, last_used_days_ago: 2)
        stock_up(item, 3)
        item
      end
      let!(:expired) do
        item = create(:item, name: "レトルトカレー", tracks_expiry: true)
        create(:lot, item: item, initial_quantity: 2, expires_on: Date.current - 1)
        item
      end
      let!(:expiring_soon) do
        item = create(:item, name: "ヨーグルト", tracks_expiry: true)
        create(:lot, item: item, initial_quantity: 2, expires_on: Date.current + 3)
        item
      end

      it "purchase=urgent で購入推奨の品目だけになる" do
        get items_path, params: { purchase: "urgent" }

        expect(rendered_list("品目一覧")).to include urgent.name
        expect(rendered_list("品目一覧")).not_to include soon.name
      end

      it "purchase=soon でそろそろ購入の品目だけになる" do
        get items_path, params: { purchase: "soon" }

        expect(rendered_list("品目一覧")).to include soon.name
        expect(rendered_list("品目一覧")).not_to include urgent.name
      end

      it "expiry=expired で期限切れの品目だけになる" do
        get items_path, params: { expiry: "expired" }

        expect(rendered_list("品目一覧")).to include expired.name
        expect(rendered_list("品目一覧")).not_to include expiring_soon.name
      end

      it "expiry=expiring_soon で期限間近の品目だけになる" do
        get items_path, params: { expiry: "expiring_soon" }

        expect(rendered_list("品目一覧")).to include expiring_soon.name
        expect(rendered_list("品目一覧")).not_to include expired.name
      end

      # 壊れた値で 0 件になると「品目が無い」ように見えてしまうので、既定 (絞り込まない) に倒す
      it "知らない値や壊れたパラメータは無視される" do
        get items_path, params: { purchase: "everything", expiry: [ "expired" ] }

        expect(response).to have_http_status(:ok)
        expect(rendered_list("品目一覧")).to include urgent.name
        expect(rendered_list("品目一覧")).to include soon.name
      end

      it "検索と組み合わせられる" do
        get items_path, params: { purchase: "urgent", q: "ぜったいにない" }

        expect(rendered_list("品目一覧")).not_to include urgent.name
      end

      # 予測も期限もアーカイブ済みは判定しないので、状態を「すべて」にしても出てこない
      it "状態がすべてでも、アーカイブ済みの品目は絞り込みに出てこない" do
        archived = create(:item, :archived, name: "むかしのレトルト", tracks_expiry: true)
        create(:lot, item: archived, initial_quantity: 2, expires_on: Date.current - 1)

        get items_path, params: { status: "all", expiry: "expired" }

        expect(rendered_list("品目一覧")).to include expired.name
        expect(rendered_list("品目一覧")).not_to include archived.name
      end
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

    describe "予測" do
      before { freeze_time }

      def forecast_text
        response.parsed_body.at("section[aria-label='予測']").text
      end

      it "在庫切れ予測日と残り日数とペースが出る (検算例 1)" do
        item = create(:item, name: "トイレットペーパー", unit: "ロール")
        record_usages(item, interval: 5, times: 19, last_used_days_ago: 2)
        stock_up(item, 3)

        get item_path(item)

        expect(forecast_text).to include I18n.l(Date.current + 18)
        expect(forecast_text).to include "あと 18 日"
        expect(forecast_text).to include "約 6.0 ロール / 月"
        expect(forecast_text).to include "そろそろ購入"
        expect(forecast_text).to include "消費ペースから判定しました"
      end

      it "月に 1 個も使わない品目のペースは「約 n 日に 1 個」で出す (検算例 2)" do
        item = create(:item, name: "くん煙剤", unit: "個")
        record_usages(item, interval: 182, times: 5)

        get item_path(item)

        expect(forecast_text).to include "約 182 日に 1 個"
        expect(forecast_text).to include I18n.l(Date.current + 182)
      end

      it "最低在庫数で判定したときはその旨を出す" do
        item = create(:item, name: "ティッシュ", unit: "箱", minimum_quantity: 5)
        create(:lot, item: item, initial_quantity: 3)

        get item_path(item)

        expect(forecast_text).to include "購入推奨"
        expect(forecast_text).to include "最低在庫数 (5 箱) との比較で判定しました"
        # 境界は「ちょうどならそろそろ購入、下回ったら購入推奨」(仕様 7 節)
        expect(forecast_text).to include "ちょうどで「そろそろ購入」"
        expect(forecast_text).to include "下回ると「購入推奨」になります"
      end

      # 判定が出ているのに画面に何も出ないと「壊れている」ように見える
      it "購入不要のときも詳細には判定を文字で出す" do
        item = create(:item, name: "トイレットペーパー", unit: "ロール")
        record_usages(item, interval: 5, times: 19)
        stock_up(item, 200)

        get item_path(item)

        expect(Forecast::ItemForecaster.call(item.reload).status).to eq :ok
        expect(forecast_text).to include "購入不要"
      end

      # 仕様 9 節「need_by_on が過去なら today に丸める」。在庫が残っているのに
      # 「在庫切れ予測日: 今日」とだけ出すと誤解を生む
      it "在庫が残ったまま予測日が過ぎているときは棚卸を促す" do
        item = create(:item, name: "トイレットペーパー", unit: "ロール")
        record_usages(item, interval: 5, times: 19, last_used_days_ago: 40)
        stock_up(item, 3)

        get item_path(item)

        forecast = Forecast::ItemForecaster.call(item.reload)
        expect(forecast.days_left).to eq 0
        expect(forecast.quantity).to eq 3
        expect(forecast_text).to include "買っておくべき期限はすでに過ぎています"
        expect(forecast_text).to include "在庫数が合っているか確認してください"
      end

      it "在庫 0 でペースが分からなければその旨を出す" do
        item = create(:item, name: "ぼうさいようひん")
        stock_up(item, 1, days_ago: 30)
        record_usage(item, days_ago: 0)

        get item_path(item)

        expect(forecast_text).to include "購入推奨"
        expect(forecast_text).to include "在庫が 0 で、消費ペースがまだ分かりません"
      end

      # データ不足でも不安にさせない (docs/spec/03-screens.md ステータスの見せ方)
      it "使用の記録が 1 件だけなら「2 回たまると予測を始めます」と出す" do
        item = create(:item, name: "しょうゆ")
        stock_up(item, 5, days_ago: 60)
        record_usage(item, days_ago: 10)

        get item_path(item)

        # 同じ日に 2 回記録しても消費イベントは 1 件なので「別の日に」と書く
        expect(forecast_text).to include "使用の記録が別の日に 2 回たまると予測を始めます"
      end

      # 「あと n 日」とは書けない。窓の両端が消費イベント日のときは日が経っても
      # observed_days が増えず、いつまでも同じ日数を言い続けてしまう
      it "観測日数が足りなければ日数を言わずに予測開始の目安を出す" do
        item = create(:item, name: "あたらしいひん")
        stock_up(item, 10, days_ago: 4)
        record_usage(item, days_ago: 3)
        record_usage(item, days_ago: 0)

        get item_path(item)

        expect(forecast_text).to include "観測期間がまだ短いため、次の使用の記録から予測を始めます"
        expect(forecast_text).not_to include "日ぶんの記録"
      end

      it "予測しない設定の品目にはその旨を出す" do
        item = create(:item, name: "ひじょうしょく", estimation_mode: :none)
        stock_up(item, 5, days_ago: 60)

        get item_path(item)

        expect(forecast_text).to include "予測しない設定です"
      end

      it "在庫を 1 件も登録していない品目にはその旨を出す" do
        item = create(:item, name: "とうろくしたばかり")

        get item_path(item)

        expect(forecast_text).to include "在庫を登録すると予測を始めます"
        expect(forecast_text).to include "在庫が 0 で、消費ペースがまだ分かりません"
      end

      it "データ不足のときは判定の理由を出さない (何がたまれば始まるかだけを出す)" do
        item = create(:item, name: "しょうゆ")
        stock_up(item, 5, days_ago: 60)
        record_usage(item, days_ago: 10)

        get item_path(item)

        expect(forecast_text).not_to include "判定しました"
        expect(forecast_text).not_to include "消費ペース"
      end

      it "期限切れのロットを在庫に数えていないことを添える" do
        item = create(:item, name: "レトルトカレー", tracks_expiry: true)
        create(:lot, item: item, initial_quantity: 2, expires_on: Date.current - 1)

        get item_path(item)

        expect(forecast_text).to include "期限切れの 1 ロットは、この判定の在庫に数えていません"
      end
    end

    describe "期限" do
      before { freeze_time }

      let(:item) { create(:item, name: "レトルトカレー", unit: "箱", tracks_expiry: true) }

      def expiry_text
        response.parsed_body.at("section[aria-label='期限']")&.text.to_s
      end

      it "最も近い期限と期限切れの数が出て、廃棄に進める" do
        create(:lot, item: item, initial_quantity: 2, expires_on: Date.current - 1)
        create(:lot, item: item, initial_quantity: 3, expires_on: Date.current + 100)

        get item_path(item)

        expect(expiry_text).to include "期限切れ"
        expect(expiry_text).to include I18n.l(Date.current - 1)
        expect(expiry_text).to include "期限切れのロット: 1 件"
        expect(response.body).to include new_item_disposal_path(item)
      end

      it "期限が近いロットの数が出る" do
        create(:lot, item: item, initial_quantity: 3, expires_on: Date.current + 3)

        get item_path(item)

        expect(expiry_text).to include "期限間近"
        expect(expiry_text).to include "期限が近いロット: 1 件"
      end

      it "期限を入れたロットが無ければ期限のセクションを出さない" do
        create(:lot, item: item, initial_quantity: 3, expires_on: nil)

        get item_path(item)

        expect(response.parsed_body.at("section[aria-label='期限']")).to be_nil
      end
    end

    describe "ロット一覧" do
      let(:item) { create(:item, name: "トイレットペーパー", unit: "ロール", tracks_expiry: true) }

      it "残数・期限・購入日・店舗・単価が出る" do
        create(:lot, item: item, initial_quantity: 12, price_yen: 456,
          acquired_on: Date.current - 3, expires_on: Date.current + 30,
          store: create(:store, name: "あおぞらスーパー"))

        get item_path(item)

        lots = rendered_list("ロット一覧")
        expect(lots).to include "残り 12 ロール"
        expect(lots).to include I18n.l(Date.current + 30)  # 期限
        expect(lots).to include I18n.l(Date.current - 3)   # 購入日
        expect(lots).to include "あおぞらスーパー"
        expect(lots).to include "38円/ロール"              # 456 / 12
      end

      it "在庫のあるロットは期限が近い順に並ぶ" do
        create(:lot, item: item, initial_quantity: 1, expires_on: Date.current + 30, note: "あとの期限")
        create(:lot, item: item, initial_quantity: 1, expires_on: Date.current + 3, note: "さきの期限")

        get item_path(item)

        lots = rendered_list("ロット一覧")
        expect(lots.index("さきの期限")).to be < lots.index("あとの期限")
      end

      # 残 0 のロットは畳んで、在庫のあるロットだけを前に出す
      it "使い切ったロットはロット一覧に出ず、畳まれた一覧に入る" do
        depleted = create(:lot, item: item, initial_quantity: 3, note: "つかいきった")
        create(:lot, item: item, initial_quantity: 5, note: "のこってる")
        create(:stock_movement, lot: depleted, kind: :usage, quantity: -3)
        Stock::Recalculator.call(item)

        get item_path(item)

        expect(rendered_list("ロット一覧")).to include "のこってる"
        expect(rendered_list("ロット一覧")).not_to include "つかいきった"
        expect(rendered_list("使い切ったロット一覧")).to include "つかいきった"
      end

      # 判定 (在庫 q からの除外・期限切れバッジ) は expires_on の有無で行うので、
      # 「期限を管理する」を外した品目でも期限は必ず見せる (でないと直しようがない)
      it "期限を管理しない品目でも、期限が入っていればロット一覧に出す" do
        plain = create(:item, name: "むかしは期限を管理していた", unit: "個")
        create(:lot, item: plain, initial_quantity: 2, expires_on: Date.current - 1)

        get item_path(plain)

        lots = rendered_list("ロット一覧")
        expect(lots).to include I18n.l(Date.current - 1)
        expect(lots).to include "期限切れ"
      end

      it "ロットが無ければその旨を出す" do
        get item_path(item)

        expect(response.body).to include "在庫のあるロットはまだありません"
      end

      # 調整ロット (価格 nil) で平均が歪まないようにする
      it "単価の平均は価格のあるロットだけで計算する" do
        create(:lot, item: item, initial_quantity: 12, price_yen: 456)
        create(:lot, item: item, initial_quantity: 10, price_yen: 200)
        create(:lot, item: item, initial_quantity: 100, price_yen: nil)

        get item_path(item)

        expect(response.parsed_body.at("section[aria-label='ロット']").text).to include "平均 30円/ロール"
      end

      it "10 円未満の単価は小数 1 桁で出す (0 円に潰さない)" do
        create(:lot, item: item, initial_quantity: 100, price_yen: 30)

        get item_path(item)

        expect(rendered_list("ロット一覧")).to include "0.3円/ロール"
      end

      # 何年も使っている品目で、使い切ったロットの行が無限に伸びないようにする
      it "使い切ったロットは新しいものから決まった件数だけ出す" do
        stub_const("ItemDetails::DEPLETED_LOTS_LIMIT", 1)
        old = create(:lot, item: item, initial_quantity: 1, acquired_on: Date.current - 10,
          note: "ふるいロット")
        recent = create(:lot, item: item, initial_quantity: 1, note: "あたらしいロット")
        [ old, recent ].each { |lot| create(:stock_movement, lot: lot, kind: :usage, quantity: -1) }
        Stock::Recalculator.call(item)

        get item_path(item)

        expect(rendered_list("使い切ったロット一覧")).to include "あたらしいロット"
        expect(rendered_list("使い切ったロット一覧")).not_to include "ふるいロット"
        expect(response.body).to include "使い切ったロット (2 件)"
      end

      it "価格のあるロットが無ければ平均は出さない" do
        create(:lot, item: item, initial_quantity: 12, price_yen: nil)

        get item_path(item)

        expect(response.parsed_body.at("section[aria-label='ロット']").text).not_to include "平均"
      end

      it "ロットが増えてもクエリ数は増えない (店舗を includes している)" do
        # 店舗が 1 件だと「ロット一覧」と「最近の記録」の店舗の読み込みが同じ SQL になり、
        # 2 本目がクエリキャッシュに当たって数えられない。基準は 2 件から始める
        2.times { create(:lot, item: item, store: create(:store)) }
        get item_path(item) # ウォームアップ

        baseline = count_queries { get item_path(item) }
        3.times { create(:lot, item: item, store: create(:store)) }

        expect(count_queries { get item_path(item) }).to eq baseline
      end

      it "「購入を記録」から購入の入力フォームへ行ける" do
        get item_path(item)

        expect(response.body).to include new_item_lot_path(item)
      end

      # 調整ロット (在庫不足の補填・棚卸) は画面から編集できない (LotsController は 404)
      it "調整ロットには編集リンクを出さない" do
        create(:lot, :adjustment, item: item, initial_quantity: 3)

        get item_path(item)

        expect(rendered_list("ロット一覧")).to include "調整"
        expect(response.parsed_body.at("ul[aria-label='ロット一覧'] a")).to be_nil
      end
    end

    describe "用途一覧" do
      let(:item) { create(:item, name: "単 3 電池", unit: "本", tracks_purposes: true) }

      def use(purpose, *days_ago)
        days_ago.each do |ago|
          create(:usage_record, item: item, item_purpose: purpose, used_on: Date.current - ago)
        end
      end

      it "最終交換日と交換周期 (中央値) が出る" do
        use(create(:item_purpose, item: item, name: "リモコン"), 90, 60, 30, 0)

        get item_path(item)

        purposes = rendered_list("用途一覧")
        expect(purposes).to include "リモコン"
        expect(purposes).to include I18n.l(Date.current)
        expect(purposes).to include "約 30 日"
      end

      it "記録が 1 件の用途には最終交換日だけが出る" do
        use(create(:item_purpose, item: item, name: "時計"), 5)

        get item_path(item)

        expect(rendered_list("用途一覧")).to include I18n.l(Date.current - 5)
        expect(rendered_list("用途一覧")).not_to include "交換周期: 約"
      end

      it "まだ使っていない用途はその旨を出す" do
        create(:item_purpose, item: item, name: "リモコン")

        get item_path(item)

        expect(rendered_list("用途一覧")).to include "まだ使用の記録がありません"
      end

      it "アーカイブ済みの用途は出ない" do
        create(:item_purpose, item: item, name: "リモコン")
        create(:item_purpose, :archived, item: item, name: "むかしの用途")

        get item_path(item)

        expect(rendered_list("用途一覧")).not_to include "むかしの用途"
      end

      it "用途を管理しない品目には用途の欄を出さない" do
        get item_path(create(:item, name: "トイレットペーパー"))

        expect(response.parsed_body.at("section[aria-label='用途']")).to be_nil
      end

      it "用途が増えてもクエリ数は増えない (usage_records を includes)" do
        use(create(:item_purpose, item: item, name: "リモコン"), 30, 0)
        before_count = count_queries { get item_path(item) }

        use(create(:item_purpose, item: item, name: "時計"), 20, 0)

        expect(count_queries { get item_path(item) }).to eq before_count
      end
    end

    describe "最近の記録" do
      let(:item) { create(:item, name: "トイレットペーパー", unit: "ロール") }

      it "使用と購入が新しい順に並ぶ" do
        create(:lot, item: item, initial_quantity: 12, acquired_on: Date.current - 3)
        create(:usage_record, item: item, quantity: 2, used_on: Date.current)

        get item_path(item)

        records = rendered_list("最近の記録一覧")
        expect(records).to include "使った 2 ロール"
        expect(records).to include "購入 12 ロール"
        expect(records.index("使った")).to be < records.index("購入")
      end

      it "各行から編集できる" do
        lot = create(:lot, item: item, initial_quantity: 12)
        usage = create(:usage_record, item: item, quantity: 2)

        get item_path(item)

        expect(response.body).to include edit_usage_record_path(usage)
        expect(response.body).to include edit_lot_path(lot)
      end

      it "用途も出る" do
        purposes_item = create(:item, name: "単 3 電池", unit: "本", tracks_purposes: true)
        purpose = create(:item_purpose, item: purposes_item, name: "リモコン")
        create(:usage_record, item: purposes_item, item_purpose: purpose)

        get item_path(purposes_item)

        expect(rendered_list("最近の記録一覧")).to include "リモコン"
      end

      # 在庫不足の補填で作られる調整ロットはユーザーの操作ではない
      it "補填の調整ロットは購入として出さない" do
        create(:usage_record, item: item, quantity: 2)

        get item_path(item)

        expect(rendered_list("最近の記録一覧")).not_to include "調整"
      end

      it "記録が無ければその旨を出す" do
        get item_path(item)

        expect(response.parsed_body.at("section[aria-label='最近の記録']").text)
          .to include "まだ記録がありません"
      end

      # 行ごとに用途と店舗を出すので、includes しないと記録の数だけクエリが増える
      it "記録が増えてもクエリ数は増えない (用途と店舗を includes)" do
        purposes_item = create(:item, tracks_purposes: true)
        purpose = create(:item_purpose, item: purposes_item, name: "リモコン")
        # 店舗が 1 件だとクエリキャッシュに当たって基準が 1 本少なくなる (上のロット一覧の spec と同じ)
        2.times { create(:lot, item: purposes_item, initial_quantity: 20, store: create(:store)) }
        create(:usage_record, item: purposes_item, item_purpose: purpose)
        get item_path(purposes_item) # ウォームアップ

        baseline = count_queries { get item_path(purposes_item) }
        3.times do
          create(:lot, item: purposes_item, initial_quantity: 2, store: create(:store))
          create(:usage_record, item: purposes_item, item_purpose: purpose)
        end

        expect(count_queries { get item_path(purposes_item) }).to eq baseline
      end
    end

    describe "「使った」ボタン" do
      it "用途を管理しない品目にはワンタップの「使った」が出る" do
        item = create(:item, name: "トイレットペーパー")

        get item_path(item)

        expect(response.parsed_body.at("form[action='#{item_quick_use_path(item)}']")).to be_present
      end

      it "用途を管理する品目は用途を選べるフォームだけを出す" do
        item = create(:item, name: "単 3 電池", tracks_purposes: true)

        get item_path(item)

        expect(response.parsed_body.at("form[action='#{item_quick_use_path(item)}']")).to be_nil
        expect(response.body).to include new_item_usage_record_path(item)
      end
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
