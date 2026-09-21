require "rails_helper"

RSpec.describe "まとめ購入", type: :request do
  before { freeze_time }

  let(:user) { create(:user, name: "おかあさん") }

  before { sign_in user }

  def urgent_item(name: "ティッシュ", **attributes)
    create(:item, name: name, minimum_quantity: 5, **attributes).tap { |item| stock_up(item, 3) }
  end

  def check(item)
    create(:shopping_list_item, :checked, item: item, added_by: user)
  end

  def line_params(entry, **attributes)
    { entry.id.to_s => { initial_quantity: "2" }.merge(attributes) }
  end

  describe "GET /purchases/new" do
    it "チェック済みの品目が並ぶ" do
      check(urgent_item(name: "ティッシュ"))

      get new_purchase_path

      expect(response).to have_http_status(:ok)
      expect(rendered_list("購入する品目")).to include "ティッシュ"
    end

    it "希望数量が数量の初期値になる" do
      check(urgent_item(name: "ティッシュ")).update!(quantity: 7)

      get new_purchase_path

      expect(response.parsed_body.at("input[name$='[initial_quantity]']")[:value]).to eq "7"
    end

    # 両方を埋めると、数量だけ書き換えたときに積が黙って勝ってしまう
    it "入数の既定値があれば「入数 × パック数」だけを埋めて開く" do
      check(urgent_item(name: "ティッシュ", default_pack_size: 5))

      get new_purchase_path

      expect(response.parsed_body.at("input[name$='[pack_size]']")[:value]).to eq "5"
      expect(response.parsed_body.at("input[name$='[pack_count]']")[:value]).to eq "1"
      expect(response.parsed_body.at("input[name$='[initial_quantity]']")[:value]).to be_blank
    end

    it "期限の欄は「期限を管理する」品目にだけ出る" do
      check(urgent_item(name: "ぎゅうにゅう", tracks_expiry: true))
      check(urgent_item(name: "ティッシュ"))

      get new_purchase_path

      expect(response.parsed_body.css("input[name$='[expires_on]']").size).to eq 1
    end

    it "自由入力のチェック済みは在庫に記録されないことを明示する" do
      check(urgent_item)
      entry = create(:shopping_list_item, :free_text, :checked, free_text: "はがき", added_by: user)

      get new_purchase_path

      expect(response.body).to include "在庫には記録されません"
      expect(rendered_list("自由入力の品目")).to include "はがき"
      # この画面に出ていた行だけを消すために id を持ち回る
      expect(response.parsed_body.at("input[name='purchase[free_text_ids][]'][value='#{entry.id}']"))
        .to be_present
    end

    it "チェック済みが 0 件なら買い物リストに戻す" do
      urgent_item

      get new_purchase_path

      expect(response).to redirect_to shopping_list_path
      expect(flash[:alert]).to be_present
    end

    it "チェック済みが自由入力だけなら、在庫に記録できないことを伝えて戻す" do
      create(:shopping_list_item, :free_text, :checked, added_by: user)

      get new_purchase_path

      expect(response).to redirect_to shopping_list_path
      expect(flash[:alert]).to include "自由入力"
      expect(flash[:alert]).to include "リストから外す"
    end

    it "アーカイブ済みの品目のチェック済み行は並ばない" do
      item = urgent_item(name: "アーカイブずみ")
      check(item)
      item.archive!

      get new_purchase_path

      expect(response).to redirect_to shopping_list_path
    end
  end

  describe "POST /purchases" do
    it "チェック済みの品目をまとめて記録し、在庫が増えて行が消える" do
      first = urgent_item(name: "ティッシュ")
      second = urgent_item(name: "しょうゆ")
      store = create(:store, name: "スーパー")
      entries = [ check(first), check(second) ]

      expect {
        post purchases_path, params: { purchase: {
          acquired_on: Date.current.to_s, store_id: store.id,
          lines: line_params(entries.first, initial_quantity: "4")
            .merge(line_params(entries.second, initial_quantity: "6", price_yen: "298"))
        } }
      }.to change(Lot, :count).by(2)

      expect(response).to redirect_to shopping_list_path
      expect(first.reload.current_quantity).to eq 7
      expect(second.reload.current_quantity).to eq 9
      expect(second.lots.order(:id).last.price_yen).to eq 298
      expect(second.lots.order(:id).last.store).to eq store
      expect(ShoppingListItem.count).to eq 0
    end

    it "記録した品目は要購入ではなくなり、買い物リストから消える" do
      item = urgent_item(name: "ティッシュ")
      entry = check(item)

      post purchases_path, params: { purchase: {
        acquired_on: Date.current.to_s, lines: line_params(entry, initial_quantity: "10")
      } }

      expect(Forecast::ItemForecaster.call(item.reload, today: Date.current).status).to eq :ok
      get shopping_list_path
      expect(rendered_list("要購入の品目")).not_to include "ティッシュ"
    end

    it "入数 × パック数で数量を入れられる" do
      item = urgent_item
      entry = check(item)

      post purchases_path, params: { purchase: {
        acquired_on: Date.current.to_s,
        lines: line_params(entry, initial_quantity: "1", pack_size: "12", pack_count: "2")
      } }

      expect(item.reload.lots.order(:id).last.initial_quantity).to eq 24
    end

    it "1 件でも検証エラーなら 1 件も記録せず、422 で入力を保ったまま描き直す" do
      first = urgent_item(name: "ティッシュ")
      second = urgent_item(name: "しょうゆ")
      entries = [ check(first), check(second) ]

      expect {
        post purchases_path, params: { purchase: {
          acquired_on: Date.current.to_s,
          lines: line_params(entries.first, initial_quantity: "4")
            .merge(line_params(entries.second, initial_quantity: "0"))
        } }
      }.not_to change(Lot, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(first.reload.current_quantity).to eq 3
      expect(ShoppingListItem.count).to eq 2
      # 入力は消さない
      expect(response.parsed_body.at("input[name='purchase[lines][#{entries.first.id}][initial_quantity]']")[:value])
        .to eq "4"
    end

    it "未来の購入日は記録できない" do
      entry = check(urgent_item)

      expect {
        post purchases_path, params: { purchase: {
          acquired_on: (Date.current + 1).to_s, lines: line_params(entry)
        } }
      }.not_to change(Lot, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    # 壊れた値 (uuid に cast できない) と、形は正しいが存在しない UUID の両方
    it "存在しない店舗では記録できない (外部キー違反で 500 にしない)" do
      [ "0", nonexistent_uuid ].each do |store_id|
        entry = check(urgent_item)

        post purchases_path, params: { purchase: {
          acquired_on: Date.current.to_s, store_id: store_id, lines: line_params(entry)
        } }

        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    it "4 バイト整数をはみ出す数量でも 500 にしない" do
      entry = check(urgent_item)

      post purchases_path, params: { purchase: {
        acquired_on: Date.current.to_s, lines: line_params(entry, initial_quantity: "99999999999")
      } }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "フォームに出ていた自由入力のチェック済み行も一緒に消える (在庫には記録しない)" do
      entry = check(urgent_item)
      free_text = create(:shopping_list_item, :free_text, :checked, free_text: "はがき", added_by: user)

      expect {
        post purchases_path, params: { purchase: {
          acquired_on: Date.current.to_s, lines: line_params(entry),
          free_text_ids: [ free_text.id.to_s ]
        } }
      }.to change(Lot, :count).by(1)

      expect(ShoppingListItem.count).to eq 0
      expect(flash[:notice]).to include "自由入力"
    end

    # 開いている間に家族がチェックした行を、見ないまま消さない
    it "フォームに出ていなかったチェック済みの自由入力は残る" do
      entry = check(urgent_item)
      later = create(:shopping_list_item, :free_text, :checked, free_text: "でんち", added_by: user)

      post purchases_path, params: { purchase: {
        acquired_on: Date.current.to_s, lines: line_params(entry), free_text_ids: []
      } }

      expect(ShoppingListItem.pluck(:id)).to eq [ later.id ]
      expect(flash[:notice]).not_to include "自由入力"
    end

    it "チェックしていない行は消さない" do
      entry = check(urgent_item)
      other = create(:shopping_list_item, :free_text, :manual, free_text: "のこる", added_by: user)

      post purchases_path, params: { purchase: {
        acquired_on: Date.current.to_s, lines: line_params(entry)
      } }

      expect(ShoppingListItem.pluck(:id)).to eq [ other.id ]
    end

    it "他の人が先に記録していたら、すでに購入済みだと伝えて何も記録しない" do
      entry = check(urgent_item)
      params = { purchase: { acquired_on: Date.current.to_s, lines: line_params(entry) } }
      entry.destroy!

      expect { post purchases_path, params: params }.not_to change(Lot, :count)

      expect(response).to redirect_to shopping_list_path
      expect(flash[:alert]).to include "すでに購入済み"
    end

    # 残りだけを黙って記録すると、何が記録されたのか分からなくなる
    it "送った行の一部だけが先に購入済みなら、1 件も記録せずに知らせる" do
      entries = [ check(urgent_item(name: "ティッシュ")), check(urgent_item(name: "しょうゆ")) ]
      params = { purchase: { acquired_on: Date.current.to_s,
                             lines: line_params(entries.first).merge(line_params(entries.second)) } }
      entries.first.destroy!

      expect { post purchases_path, params: params }.not_to change(Lot, :count)

      expect(response).to redirect_to shopping_list_path
      expect(flash[:alert]).to include "すでに購入済み"
      expect(entries.second.reload).to be_checked
    end

    it "フォームを開いている間にチェックが外されていたら、1 件も記録しない" do
      entry = check(urgent_item)
      params = { purchase: { acquired_on: Date.current.to_s, lines: line_params(entry) } }
      entry.update!(checked_at: nil)

      expect { post purchases_path, params: params }.not_to change(Lot, :count)

      expect(flash[:alert]).to include "すでに購入済み"
    end

    it "壊れた形の行のパラメータでも 500 にしない" do
      check(urgent_item)

      post purchases_path, params: { purchase: "こわれている" }

      expect(response).to redirect_to shopping_list_path
    end

    it "行が 1 つも送られなければ買い物リストに戻す" do
      check(urgent_item)

      post purchases_path, params: { purchase: { acquired_on: Date.current.to_s } }

      expect(response).to redirect_to shopping_list_path
    end
  end

  # 数量の上書きだけが残った行を放っておくと、数か月後にまた urgent に戻ったときに
  # 古い上書きが復活する (docs/spec/01-domain-model.md 判断 5)
  describe "単品の購入 (POST /items/:id/lots)" do
    it "買い物リストの行は、チェックも数量の上書きも手動の印もまとめて片づく" do
      item = urgent_item
      create(:shopping_list_item, :checked, :manual, item: item, added_by: user, quantity: 9)

      expect {
        post item_lots_path(item), params: { lot: { acquired_on: Date.current.to_s,
                                                    initial_quantity: "10" } }
      }.to change(ShoppingListItem, :count).by(-1)

      expect(response).to redirect_to item_path(item)
    end

    it "ほかの品目の行と自由入力の行は残す" do
      item = urgent_item
      other = create(:shopping_list_item, :checked, item: urgent_item(name: "べつのしな"), added_by: user)
      free_text = create(:shopping_list_item, :free_text, :checked, added_by: user)
      create(:shopping_list_item, item: item, added_by: user, quantity: 2)

      post item_lots_path(item), params: { lot: { acquired_on: Date.current.to_s,
                                                  initial_quantity: "10" } }

      expect(ShoppingListItem.pluck(:id)).to match_array [ other.id, free_text.id ]
    end
  end
end
