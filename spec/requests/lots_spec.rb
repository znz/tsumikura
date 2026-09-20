require "rails_helper"

RSpec.describe "購入の記録", type: :request do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:user) { create(:user) }
  let(:item) { create(:item, name: "トイレットペーパー", unit: "ロール") }

  before { sign_in user }

  # 直接入力の数量。入数・パック数を送らない = JS で「直接入力」を選んだときの送信内容
  def purchase_params(attributes = {})
    { lot: { acquired_on: Date.current.to_s, initial_quantity: "12" }.merge(attributes) }
  end

  describe "GET /items/:item_id/lots/new (購入の入力フォーム)" do
    it "開ける" do
      get new_item_lot_path(item)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include "トイレットペーパー"
    end

    it "入数の初期値は品目の既定値" do
      item.update!(default_pack_size: 12)

      get new_item_lot_path(item)

      expect(response.parsed_body.at("input[name='lot[pack_size]']")[:value]).to eq "12"
      expect(response.parsed_body.at("input[name='lot[pack_count]']")[:value]).to eq "1"
    end

    it "入数の既定値が無ければ入数は空" do
      get new_item_lot_path(item)

      expect(response.parsed_body.at("input[name='lot[pack_size]']")[:value]).to be_blank
    end

    it "購入日の初期値は今日" do
      get new_item_lot_path(item)

      expect(response.parsed_body.at("input[name='lot[acquired_on]']")[:value]).to eq Date.current.to_s
    end

    # 期限日は期限を管理する品目だけに出す (docs/spec/03-screens.md 画面 5)
    it "期限を管理する品目には期限日の入力欄が出る" do
      expiring = create(:item, :tracks_expiry)

      get new_item_lot_path(expiring)

      expect(response.parsed_body.at("input[name='lot[expires_on]']")).to be_present
    end

    it "期限を管理しない品目には期限日の入力欄を出さない" do
      get new_item_lot_path(item)

      expect(response.parsed_body.at("input[name='lot[expires_on]']")).to be_nil
    end

    it "JS が無いときのために、数量の 3 つの入力欄がすべて出ている" do
      get new_item_lot_path(item)

      %w[ lot[pack_size] lot[pack_count] lot[initial_quantity] ].each do |name|
        expect(response.parsed_body.at("input[name='#{name}']")).to be_present
      end
    end

    it "存在しない品目は 404" do
      get new_item_lot_path(item_id: 0)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /items/:item_id/lots (購入の記録)" do
    it "Lot と StockMovement が 1 件ずつ作られ、在庫が増える" do
      expect {
        post item_lots_path(item), params: purchase_params
      }.to change { Lot.count }.by(1).and change { StockMovement.count }.by(1)

      expect(item.reload.current_quantity).to eq 12
      expect(response).to redirect_to item_path(item)
      follow_redirect!
      expect(response.body).to include "記録しました"
    end

    it "記録者はログイン中のユーザー" do
      post item_lots_path(item), params: purchase_params

      expect(Lot.order(:id).last.user).to eq user
    end

    it "2 回記録すると在庫は合計になる" do
      post item_lots_path(item), params: purchase_params(initial_quantity: "12")
      post item_lots_path(item), params: purchase_params(initial_quantity: "3")

      expect(item.reload.current_quantity).to eq 15
    end

    # JS が無い環境では入数・パック数・数量がすべて送られてくる。
    # そのときは「入数 × パック数」を採る (docs/spec/03-screens.md 画面 5)
    it "入数 12 × パック数 2 を送ると数量 24 になる" do
      post item_lots_path(item), params: purchase_params(pack_size: "12", pack_count: "2")

      lot = Lot.order(:id).last
      expect(lot.initial_quantity).to eq 24
      expect(item.reload.current_quantity).to eq 24
    end

    it "入数・パック数・直接入力をすべて送ると、入数 × パック数が優先される (JS 無しの経路)" do
      post item_lots_path(item), params: purchase_params(pack_size: "12", pack_count: "2", initial_quantity: "1")

      expect(item.reload.current_quantity).to eq 24
    end

    it "入数だけを送ると直接入力の数量が使われ、入数は記録しない" do
      post item_lots_path(item), params: purchase_params(pack_size: "12", pack_count: "", initial_quantity: "5")

      lot = Lot.order(:id).last
      expect(lot.initial_quantity).to eq 5
      expect(lot.pack_size).to be_nil
      expect(item.reload.current_quantity).to eq 5
    end

    it "店舗・金額・メモも記録できる" do
      store = create(:store, name: "あおぞらスーパー")

      post item_lots_path(item), params: purchase_params(store_id: store.id, price_yen: "456", note: "特売")

      lot = Lot.order(:id).last
      expect(lot.store).to eq store
      expect(lot.price_yen).to eq 456
      expect(lot.note).to eq "特売"
    end

    it "期限を管理する品目では期限日を記録できる" do
      expiring = create(:item, :tracks_expiry)

      post item_lots_path(expiring), params: purchase_params(expires_on: (Date.current + 30).to_s)

      expect(Lot.order(:id).last.expires_on).to eq Date.current + 30
    end

    it "初期在庫として記録できる (movement は入庫)" do
      post item_lots_path(item), params: purchase_params(kind: "initial")

      lot = Lot.order(:id).last
      expect(lot).to be_kind_initial
      expect(lot.stock_movements.sole).to be_kind_purchase
      expect(item.reload.current_quantity).to eq 12
    end

    # 調整ロットは棚卸 (Phase 9) と在庫不足時の自動補填 (Phase 8) だけが作る
    it "種別に調整を送っても購入として記録される" do
      post item_lots_path(item), params: purchase_params(kind: "adjustment")

      expect(Lot.order(:id).last).to be_kind_purchase
    end

    it "知らない種別を送っても 500 にせず購入として記録する" do
      post item_lots_path(item), params: purchase_params(kind: "gift")

      expect(response).to redirect_to item_path(item)
      expect(Lot.order(:id).last).to be_kind_purchase
    end

    # アーカイブは「一覧から外す」だけで記録を禁じるものではない
    # (docs/spec/01-domain-model.md 3 節)
    it "アーカイブ済みの品目にも記録できる" do
      archived = create(:item, :archived)

      expect {
        post item_lots_path(archived), params: purchase_params
      }.to change { Lot.count }.by(1)

      expect(archived.reload.current_quantity).to eq 12
    end

    describe "保存できない入力" do
      it "未来の日付は 422 で、Lot も movement も作られない" do
        travel_to Time.zone.parse("2026-09-20 00:10") do
          expect {
            post item_lots_path(item), params: purchase_params(acquired_on: (Date.current + 1).to_s)
          }.not_to change { [ Lot.count, StockMovement.count ] }
        end

        expect(response).to have_http_status(:unprocessable_content)
        expect(item.reload.current_quantity).to eq 0
      end

      it "今日の日付は記録できる (境界)" do
        travel_to Time.zone.parse("2026-09-20 23:50") do
          post item_lots_path(item), params: purchase_params(acquired_on: Date.current.to_s)
        end

        expect(response).to redirect_to item_path(item)
      end

      it "数量が空なら 422" do
        expect {
          post item_lots_path(item), params: purchase_params(initial_quantity: "")
        }.not_to change { Lot.count }

        expect(response).to have_http_status(:unprocessable_content)
      end

      it "数量が 0 なら 422" do
        post item_lots_path(item), params: purchase_params(initial_quantity: "0")

        expect(response).to have_http_status(:unprocessable_content)
      end

      it "4 バイト整数をはみ出す数量でも 500 にならず 422" do
        expect {
          post item_lots_path(item), params: purchase_params(initial_quantity: "99999999999")
        }.not_to change { Lot.count }

        expect(response).to have_http_status(:unprocessable_content)
      end

      it "入数 × パック数が上限を超えても 500 にならず 422" do
        expect {
          post item_lots_path(item), params: purchase_params(pack_size: "99999", pack_count: "999")
        }.not_to change { Lot.count }

        expect(response).to have_http_status(:unprocessable_content)
      end

      it "4 バイト整数をはみ出す金額でも 500 にならず 422" do
        post item_lots_path(item), params: purchase_params(price_yen: "99999999999")

        expect(response).to have_http_status(:unprocessable_content)
      end

      it "削除済みの店舗 id でも 500 にならず 422" do
        store = create(:store)
        store_id = store.id
        store.destroy

        expect {
          post item_lots_path(item), params: purchase_params(store_id: store_id)
        }.not_to change { Lot.count }

        expect(response).to have_http_status(:unprocessable_content)
      end

      it "lot キーが無ければ 400 (500 にしない)" do
        post item_lots_path(item), params: { acquired_on: Date.current.to_s }

        expect(response).to have_http_status(:bad_request)
      end
    end

    describe "フォームから変更できない項目" do
      it "残数・使い切った日時は渡しても台帳から再計算される" do
        post item_lots_path(item),
          params: purchase_params(remaining_quantity: "999", depleted_at: 1.day.ago.iso8601)

        lot = Lot.order(:id).last
        expect(lot.remaining_quantity).to eq 12
        expect(lot.depleted_at).to be_nil
      end

      it "記録者は渡しても変わらない" do
        other = create(:user)

        post item_lots_path(item), params: purchase_params(user_id: other.id)

        expect(Lot.order(:id).last.user).to eq user
      end

      it "品目は URL で決まる (lot[item_id] は効かない)" do
        other = create(:item)

        post item_lots_path(item), params: purchase_params(item_id: other.id)

        expect(Lot.order(:id).last.item).to eq item
        expect(other.reload.current_quantity).to eq 0
      end
    end
  end

  describe "GET /lots/:id/edit (編集フォーム)" do
    it "開ける" do
      lot = create(:lot, item: item, initial_quantity: 12)

      get edit_lot_path(lot)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.at("input[name='lot[initial_quantity]']")[:value]).to eq "12"
    end

    # 期限の判定は expires_on の有無で行う (docs/spec/02-forecast.md 12 節)。
    # 「期限を管理する」を外したあとも欄を出さないと、見えない期限で期限切れ扱いのまま直せない
    it "期限を管理しない品目でも、期限が入っているロットには期限日の入力欄を出す" do
      lot = create(:lot, item: item, initial_quantity: 3, expires_on: Date.current + 10)

      get edit_lot_path(lot)

      expect(item).not_to be_tracks_expiry
      expect(response.parsed_body.at("input[name='lot[expires_on]']")).to be_present
      expect(response.body).to include "不要なら空にしてください"
    end

    it "期限を管理せず、期限も入っていないロットには期限日の入力欄を出さない" do
      lot = create(:lot, item: item, initial_quantity: 3)

      get edit_lot_path(lot)

      expect(response.parsed_body.at("input[name='lot[expires_on]']")).to be_nil
    end

    it "種別は編集フォームに出さない" do
      lot = create(:lot, item: item)

      get edit_lot_path(lot)

      expect(response.parsed_body.at("input[name='lot[kind]']")).to be_nil
    end

    it "存在しないロットは 404" do
      get edit_lot_path(id: 0)

      expect(response).to have_http_status(:not_found)
    end

    it "保存できなかったときも入力した入数が残る" do
      post item_lots_path(item), params: { lot: { acquired_on: Date.current.to_s,
                                                  pack_size: "12", pack_count: "",
                                                  initial_quantity: "" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.at("input[name='lot[pack_size]']")[:value]).to eq "12"
    end
  end

  # 調整ロット (棚卸・在庫不足の自動補填が作る) は画面から直接いじらせない
  describe "調整ロット" do
    let(:adjustment_lot) { create(:lot, :adjustment, item: item, initial_quantity: 3) }

    it "編集フォームは 404" do
      get edit_lot_path(adjustment_lot)

      expect(response).to have_http_status(:not_found)
    end

    it "更新は 404 で、数量も変わらない" do
      patch lot_path(adjustment_lot), params: { lot: { acquired_on: Date.current.to_s,
                                                       initial_quantity: "99" } }

      expect(response).to have_http_status(:not_found)
      expect(adjustment_lot.reload.initial_quantity).to eq 3
    end

    it "削除は 404 で、ロットも残る" do
      delete lot_path(adjustment_lot)

      expect(response).to have_http_status(:not_found)
      expect(Lot.exists?(adjustment_lot.id)).to be true
    end
  end

  describe "PATCH /lots/:id (編集)" do
    let(:lot) { create(:lot, item: item, user: user, initial_quantity: 12) }

    it "数量を編集すると在庫が再計算される" do
      patch lot_path(lot), params: { lot: { acquired_on: lot.acquired_on.to_s, initial_quantity: "6" } }

      expect(lot.reload.initial_quantity).to eq 6
      expect(lot.remaining_quantity).to eq 6
      expect(item.reload.current_quantity).to eq 6
      expect(response).to redirect_to item_path(item)
    end

    it "入庫の movement も直る (台帳が正)" do
      patch lot_path(lot), params: { lot: { acquired_on: lot.acquired_on.to_s, initial_quantity: "6" } }

      expect(lot.stock_movements.sole.quantity).to eq 6
    end

    it "購入日・店舗・金額・メモを編集できる" do
      store = create(:store)

      patch lot_path(lot), params: { lot: { acquired_on: (Date.current - 3).to_s,
                                            initial_quantity: "12", store_id: store.id,
                                            price_yen: "456", note: "特売" } }

      lot.reload
      expect(lot.acquired_on).to eq Date.current - 3
      expect(lot.store).to eq store
      expect(lot.price_yen).to eq 456
      expect(lot.note).to eq "特売"
    end

    # JS があるときは隠れている側の入力欄が送られてこない。
    # DB に残った入数 × パック数で数量を上書きしてしまわないこと
    describe "入数 × パック数のロット" do
      let(:pack_lot) { create(:lot, item: item, user: user, pack_size: 12, pack_count: 2) }

      it "数量だけを送ると直接入力が勝ち、入数とパック数は消える" do
        patch lot_path(pack_lot), params: { lot: { acquired_on: pack_lot.acquired_on.to_s,
                                                   initial_quantity: "20" } }

        pack_lot.reload
        expect(pack_lot.initial_quantity).to eq 20
        expect(pack_lot.pack_size).to be_nil
        expect(pack_lot.stock_movements.sole.quantity).to eq 20
        expect(item.reload.current_quantity).to eq 20
      end

      it "入数とパック数を書き換えると掛け算が勝つ" do
        patch lot_path(pack_lot), params: { lot: { acquired_on: pack_lot.acquired_on.to_s,
                                                   pack_size: "6", pack_count: "3",
                                                   initial_quantity: "24" } }

        expect(pack_lot.reload.initial_quantity).to eq 18
        expect(item.reload.current_quantity).to eq 18
      end

      it "メモだけ書き換えても数量は変わらない" do
        patch lot_path(pack_lot), params: { lot: { acquired_on: pack_lot.acquired_on.to_s,
                                                   pack_size: "12", pack_count: "2",
                                                   initial_quantity: "24", note: "特売" } }

        pack_lot.reload
        expect(pack_lot.initial_quantity).to eq 24
        expect(pack_lot.pack_size).to eq 12
      end
    end

    it "購入日が空なら 422 (500 にしない)" do
      patch lot_path(lot), params: { lot: { acquired_on: "", initial_quantity: "12" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(lot.reload.acquired_on).to be_present
    end

    it "壊れた購入日でも 422 (500 にしない)" do
      patch lot_path(lot), params: { lot: { acquired_on: "きのう", initial_quantity: "12" } }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "既に使われた数より小さくすると 422 で在庫は変わらない" do
      create(:stock_movement, lot: lot, kind: :usage, quantity: -5)
      Stock::Recalculator.call(item)

      patch lot_path(lot), params: { lot: { acquired_on: lot.acquired_on.to_s, initial_quantity: "4" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(lot.reload.initial_quantity).to eq 12
      expect(item.reload.current_quantity).to eq 7
    end

    it "未来の日付には編集できない" do
      travel_to Time.zone.parse("2026-09-20 00:10") do
        patch lot_path(lot), params: { lot: { acquired_on: (Date.current + 1).to_s,
                                              initial_quantity: "12" } }
      end

      expect(response).to have_http_status(:unprocessable_content)
    end

    describe "フォームから変更できない項目" do
      it "種別は変えられない" do
        patch lot_path(lot), params: { lot: { acquired_on: lot.acquired_on.to_s,
                                              initial_quantity: "12", kind: "adjustment" } }

        expect(lot.reload).to be_kind_purchase
      end

      it "残数は変えられない" do
        patch lot_path(lot), params: { lot: { acquired_on: lot.acquired_on.to_s,
                                              initial_quantity: "12", remaining_quantity: "999" } }

        expect(lot.reload.remaining_quantity).to eq 12
      end

      it "記録者は変えられない" do
        other = create(:user)

        patch lot_path(lot), params: { lot: { acquired_on: lot.acquired_on.to_s,
                                              initial_quantity: "12", user_id: other.id } }

        expect(lot.reload.user).to eq user
      end

      it "品目は変えられない" do
        other = create(:item)

        patch lot_path(lot), params: { lot: { acquired_on: lot.acquired_on.to_s,
                                              initial_quantity: "12", item_id: other.id } }

        expect(lot.reload.item).to eq item
        expect(other.reload.current_quantity).to eq 0
      end
    end

    it "lot キーが無ければ 400 (500 にしない)" do
      patch lot_path(lot), params: { initial_quantity: "6" }

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "DELETE /lots/:id (削除)" do
    let!(:lot) { create(:lot, item: item, initial_quantity: 12) }

    it "削除すると在庫が元に戻る" do
      expect { delete lot_path(lot) }
        .to change { Lot.count }.by(-1)
        .and change { StockMovement.count }.by(-1)

      expect(item.reload.current_quantity).to eq 0
      expect(response).to redirect_to item_path(item)
    end

    it "使用の記録が紐づくロットは削除できず、在庫も変わらない" do
      create(:stock_movement, lot: lot, kind: :usage, quantity: -5)
      Stock::Recalculator.call(item)

      expect { delete lot_path(lot) }.not_to change { Lot.count }

      expect(item.reload.current_quantity).to eq 7
      follow_redirect!
      expect(response.body).to include "削除できません"
    end
  end
end
