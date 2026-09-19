require "rails_helper"

RSpec.describe "廃棄", type: :request do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:user) { create(:user) }
  let(:item) { create(:item, :tracks_expiry, name: "たまご", unit: "個") }

  before { sign_in user }

  def record(attributes = {})
    post item_disposals_path(item), params: { disposal: {
      quantity: "2", occurred_on: Date.current.to_s, disposal_reason: "expired"
    }.merge(attributes) }
  end

  describe "GET /items/:id/disposals/new" do
    it "理由の選択肢が 4 つ出る" do
      get new_item_disposal_path(item)

      expect(response.body).to include "期限切れ"
      expect(response.body).to include "破損"
      expect(response.body).to include "紛失"
      expect(response.body).to include "その他"
    end

    it "期限切れロットの「廃棄」からはそのロットが選ばれた状態で開く" do
      expired = create(:lot, item: item, initial_quantity: 2, expires_on: Date.current - 1)
      create(:lot, item: item, initial_quantity: 5, expires_on: Date.current + 30)

      get new_item_disposal_path(item, lot_id: expired.id)

      expect(response.parsed_body.at("option[selected][value='#{expired.id}']")).to be_present
    end

    it "在庫が無ければロットの選択は出ない" do
      get new_item_disposal_path(item)

      expect(response.body).not_to include "自動 (期限切れ"
    end
  end

  describe "POST /items/:id/disposals" do
    before { create(:lot, item: item, initial_quantity: 5) }

    it "在庫が減り、kind: disposal の記録が作られる" do
      expect { record }.to change { StockMovement.kind_disposal.count }.by(1)

      expect(item.reload.current_quantity).to eq 3
      expect(response).to redirect_to item_path(item)
    end

    it "取り消し付きのトーストで戻る" do
      record
      follow_redirect!

      expect(response.parsed_body.at("#toasts").text).to include "廃棄しました"
      expect(response.parsed_body.at("#toasts").text).to include "取り消し"
      expect(response.body).to include disposal_path(StockMovement.kind_disposal.sole)
    end

    it "取り消すと在庫が戻る" do
      record
      movement = StockMovement.kind_disposal.sole

      expect { delete disposal_path(movement) }.to change { StockMovement.count }.by(-1)
      expect(item.reload.current_quantity).to eq 5
    end

    it "在庫を超える廃棄は 422 で、在庫も記録も変わらない (500 にしない)" do
      expect { record(quantity: "9") }.not_to change { StockMovement.count }

      expect(response).to have_http_status(:unprocessable_content)
      expect(item.reload.current_quantity).to eq 5
      expect(response.body).to include "より多くできません"
    end

    it "未来の日付 / 空 / 0 / 上限超え / 知らない理由は 422 (500 にしない)" do
      [ { occurred_on: (Date.current + 1).to_s }, { quantity: "" }, { quantity: "0" },
        { quantity: "1.5" }, { quantity: "3000000000" }, { disposal_reason: "unknown" } ].each do |attributes|
        expect { record(attributes) }.not_to change { StockMovement.count }

        expect(response).to have_http_status(:unprocessable_content), attributes.inspect
      end
    end

    it "他の品目のロットは指定できず 422 (500 にしない)" do
      other_lot = create(:lot, item: create(:item), initial_quantity: 5)

      record(lot_id: other_lot.id.to_s)

      expect(response).to have_http_status(:unprocessable_content)
      expect(other_lot.reload.remaining_quantity).to eq 5
    end

    # 8 バイト整数をはみ出す id を where に渡すと PG が範囲エラーを返して 500 になる
    it "8 バイト整数をはみ出すロット id でも 422 (500 にしない)" do
      record(lot_id: (2**63).to_s)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "disposal キーが無ければ 400 (500 にしない)" do
      post item_disposals_path(item), params: {}

      expect(response).to have_http_status(:bad_request)
    end

    it "存在しない品目は 404 で、記録も作られない" do
      expect { post item_disposals_path(item_id: 0) }.not_to change { StockMovement.count }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "ロットをまたぐ廃棄" do
    before do
      create(:lot, item: item, initial_quantity: 2, expires_on: Date.current - 1)
      create(:lot, item: item, initial_quantity: 5, expires_on: Date.current + 30)
    end

    it "期限切れから先に引かれ、記録は 2 件になる" do
      expect { record(quantity: "4") }.to change { StockMovement.kind_disposal.count }.by(2)
    end

    # 取り消し先が 1 つに決まらないので、トーストにはボタンを出さない
    it "取り消しのボタンは出さず、最近の記録から消すよう伝える" do
      record(quantity: "4")
      follow_redirect!

      expect(response.parsed_body.at("#toasts").text).to include "2 つのロットに分かれた"
      expect(response.parsed_body.at("#toasts button")).to be_nil
    end
  end

  describe "DELETE /disposals/:id" do
    it "使用の記録は廃棄として消せない (404 にせず、その旨を知らせる)" do
      create(:lot, item: item, initial_quantity: 5)
      usage = Stock::RecordUsage.call(item: item, user: user,
        attributes: { quantity: 1, used_on: Date.current })

      expect { delete disposal_path(usage.stock_movements.sole) }
        .not_to change { StockMovement.count }
      expect(flash[:alert]).to include "すでに取り消されています"
    end

    # 2 台で同時に押されることがある
    it "すでに取り消された廃棄の取り消しは 404 にせず、その旨を知らせる" do
      delete disposal_path(id: 0)

      expect(flash[:alert]).to include "すでに取り消されています"
      expect(response).to redirect_to items_path
    end
  end

  describe "品目詳細の導線" do
    it "期限切れのロットに「廃棄」のリンクが出る" do
      expired = create(:lot, item: item, initial_quantity: 2, expires_on: Date.current - 1)
      create(:lot, item: item, initial_quantity: 5, expires_on: Date.current + 30)

      get item_path(item)

      expect(rendered_list("ロット一覧")).to include "期限切れ"
      expect(response.body).to include new_item_disposal_path(item, lot_id: expired.id)
    end

    it "最近の記録に廃棄が並び、そこからも取り消せる" do
      create(:lot, item: item, initial_quantity: 5)
      record

      get item_path(item)

      expect(rendered_list("最近の記録一覧")).to include "廃棄"
      expect(rendered_list("最近の記録一覧")).to include "期限切れ"
      expect(response.body).to include disposal_path(StockMovement.kind_disposal.sole)
    end

    it "最近の記録に棚卸の調整が並び、取り消しのボタンは出ない" do
      create(:lot, item: item, initial_quantity: 5)
      stock_take = create(:stock_take, user: user)
      create(:stock_take_entry, stock_take: stock_take, item: item,
        expected_quantity: 5, counted_quantity: 2)
      Stock::FinalizeStockTake.call(stock_take, user: user)

      get item_path(item)

      expect(rendered_list("最近の記録一覧")).to include "棚卸"
      expect(rendered_list("最近の記録一覧")).to include "−3"
      expect(rendered_list("最近の記録一覧")).to include "棚卸を見る"
      expect(rendered_list("最近の記録一覧")).not_to include "取り消し"
    end

    # 記録が増えてもクエリ数は増えない (includes が効いていること)
    it "廃棄と棚卸が増えても品目詳細のクエリ数は増えない" do
      create(:lot, item: item, initial_quantity: 20)
      2.times { record(quantity: "1") }
      get item_path(item)
      baseline = count_queries { get item_path(item) }

      2.times { record(quantity: "1") }

      expect(count_queries { get item_path(item) }).to eq baseline
    end
  end
end
