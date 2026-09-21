require "rails_helper"

RSpec.describe "使用の記録", type: :request do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:user) { create(:user) }
  let(:item) { create(:item, name: "トイレットペーパー", unit: "ロール") }

  before { sign_in user }

  def usage_params(attributes = {})
    { usage_record: { quantity: "1", used_on: Date.current.to_s }.merge(attributes) }
  end

  describe "GET /items/:item_id/usage_records/new (使用の入力フォーム)" do
    it "開ける。数量の初期値は 1、使用日の初期値は今日" do
      get new_item_usage_record_path(item)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include "トイレットペーパー"
      expect(response.parsed_body.at("input[name='usage_record[quantity]']")[:value]).to eq "1"
      expect(response.parsed_body.at("input[name='usage_record[used_on]']")[:value]).to eq Date.current.to_s
    end

    it "使用日には未来日を選べない max が付く" do
      get new_item_usage_record_path(item)

      expect(response.parsed_body.at("input[name='usage_record[used_on]']")[:max]).to eq Date.current.to_s
    end

    # 用途チップは用途を管理する品目だけ (docs/spec/03-screens.md 画面 4)
    it "用途を管理する品目には用途の選択肢が出る" do
      purposes_item = create(:item, tracks_purposes: true)
      purpose = create(:item_purpose, item: purposes_item, name: "リモコン")
      create(:item_purpose, :archived, item: purposes_item, name: "むかしの用途")

      get new_item_usage_record_path(purposes_item)

      expect(response.body).to include "リモコン"
      expect(response.body).not_to include "むかしの用途"
      expect(response.parsed_body.at("input[name='usage_record[item_purpose_id]'][value='#{purpose.id}']"))
        .to be_present
    end

    it "用途を管理しない品目には用途の選択肢を出さない" do
      get new_item_usage_record_path(item)

      expect(response.parsed_body.at("input[name='usage_record[item_purpose_id]']")).to be_nil
    end

    # ロットの選択は期限を管理する品目だけ。既定は FEFO の自動引き当て
    it "期限を管理する品目には在庫のあるロットの選択肢が出る" do
      expiring = create(:item, :tracks_expiry, name: "たまご")
      create(:lot, item: expiring, initial_quantity: 10, expires_on: Date.current + 7)

      get new_item_usage_record_path(expiring)

      select = response.parsed_body.at("select[name='usage_record[lot_id]']")
      expect(select).to be_present
      expect(select.text).to include "自動"
    end

    it "期限を管理しない品目にはロットの選択肢を出さない" do
      get new_item_usage_record_path(item)

      expect(response.parsed_body.at("select[name='usage_record[lot_id]']")).to be_nil
    end

    # URL の id は Base58 の 22 文字。読めない値・存在しない値・生の UUID のどれも 404
    it "引けない品目 id は 404" do
      [ 0, malformed_param, nonexistent_param, create(:item).id ].each do |item_id|
        get new_item_usage_record_path(item_id: item_id)

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "POST /items/:item_id/usage_records (使用の記録)" do
    before { create(:lot, item: item, initial_quantity: 10) }

    it "在庫が減り、品目詳細に戻る" do
      expect {
        post item_usage_records_path(item), params: usage_params(quantity: "3")
      }.to change { UsageRecord.count }.by(1).and change { StockMovement.count }.by(1)

      expect(item.reload.current_quantity).to eq 7
      expect(response).to redirect_to item_path(item)
      follow_redirect!
      expect(response.body).to include "使いました"
    end

    it "記録者はログイン中のユーザー" do
      post item_usage_records_path(item), params: usage_params

      expect(UsageRecord.order(:id).last.user).to eq user
    end

    it "過去日の記録もできる" do
      post item_usage_records_path(item), params: usage_params(used_on: (Date.current - 3).to_s)

      expect(UsageRecord.order(:id).last.used_on).to eq Date.current - 3
      expect(item.reload.current_quantity).to eq 9
    end

    it "メモも記録できる" do
      post item_usage_records_path(item), params: usage_params(note: "こぼした")

      expect(UsageRecord.order(:id).last.note).to eq "こぼした"
    end

    it "用途を指定して記録できる" do
      purpose = create(:item_purpose, item: item, name: "リモコン")

      post item_usage_records_path(item), params: usage_params(item_purpose_id: purpose.id)

      expect(UsageRecord.order(:id).last.item_purpose).to eq purpose
    end

    it "ロットを指定して記録できる" do
      lot = create(:lot, item: item, initial_quantity: 4, expires_on: Date.current + 90)

      post item_usage_records_path(item), params: usage_params(quantity: "2", lot_id: lot.id)

      expect(lot.reload.remaining_quantity).to eq 2
    end

    # アーカイブは「一覧から外す」だけで記録を禁じるものではない
    it "アーカイブ済みの品目にも記録できる" do
      archived = create(:item, :archived)
      create(:lot, item: archived, initial_quantity: 5)

      post item_usage_records_path(archived), params: usage_params

      expect(archived.reload.current_quantity).to eq 4
    end

    # 「リモコンは 2 本」を JS 無しでも効かせる (docs/spec/03-screens.md 画面 4)
    describe "数量を空で送ったとき" do
      it "用途なしなら 1 で記録される" do
        post item_usage_records_path(item), params: usage_params(quantity: "")

        expect(response).to redirect_to item_path(item)
        expect(UsageRecord.sole.quantity).to eq 1
        expect(item.reload.current_quantity).to eq 9
      end

      it "用途を選んでいればその用途の既定数量で記録される" do
        purpose = create(:item_purpose, item: item, name: "リモコン", default_quantity: 2)

        post item_usage_records_path(item), params: usage_params(quantity: "", item_purpose_id: purpose.id)

        expect(UsageRecord.sole.quantity).to eq 2
        expect(item.reload.current_quantity).to eq 8
      end
    end

    # フォームを開いている間に他の人が使い切ることがある。記録は成功させて知らせる
    it "指定したロットが使い切られていても記録でき、その旨を知らせる" do
      depleted = create(:lot, item: item, initial_quantity: 1)
      create(:usage_record, item: item, quantity: 1, lot_id: depleted.id)

      post item_usage_records_path(item), params: usage_params(lot_id: depleted.id)

      expect(response).to redirect_to item_path(item)
      follow_redirect!
      expect(response.body).to include "指定したロットは使い切られていたため"
      expect(item.reload.current_quantity).to eq 9
    end

    # 在庫記録が足りなくても記録は成功させる (設計原則 3)
    it "在庫が足りなければ調整して記録し、その旨を知らせる" do
      post item_usage_records_path(item), params: usage_params(quantity: "12")

      expect(response).to redirect_to item_path(item)
      expect(item.reload.current_quantity).to eq 0
      follow_redirect!
      expect(response.body).to include "在庫記録が不足していたため 2 ロール を調整しました"
    end

    describe "保存できない入力" do
      it "未来の日付は 422 で、何も作られない" do
        travel_to Time.current.change(hour: 0, min: 10) do
          expect {
            post item_usage_records_path(item), params: usage_params(used_on: (Date.current + 1).to_s)
          }.not_to change { [ UsageRecord.count, StockMovement.count, Lot.count ] }
        end

        expect(response).to have_http_status(:unprocessable_content)
        expect(item.reload.current_quantity).to eq 10
      end

      it "今日の日付は記録できる (境界)" do
        travel_to Time.current.change(hour: 23, min: 50) do
          post item_usage_records_path(item), params: usage_params(used_on: Date.current.to_s)
        end

        expect(response).to redirect_to item_path(item)
      end

      it "数量が 0 なら 422" do
        post item_usage_records_path(item), params: usage_params(quantity: "0")

        expect(response).to have_http_status(:unprocessable_content)
      end

      it "4 バイト整数をはみ出す数量でも 500 にならず 422" do
        expect {
          post item_usage_records_path(item), params: usage_params(quantity: "99999999999")
        }.not_to change { UsageRecord.count }

        expect(response).to have_http_status(:unprocessable_content)
      end

      it "壊れた日付でも 500 にならず 422" do
        post item_usage_records_path(item), params: usage_params(used_on: "きのう")

        expect(response).to have_http_status(:unprocessable_content)
      end

      it "他の品目の用途を指定すると 422 で、在庫も変わらない" do
        other = create(:item_purpose, item: create(:item))

        post item_usage_records_path(item), params: usage_params(item_purpose_id: other.id)

        expect(response).to have_http_status(:unprocessable_content)
        expect(item.reload.current_quantity).to eq 10
      end

      it "削除済みの用途 id でも 500 にならず 422" do
        purpose = create(:item_purpose, item: item)
        purpose_id = purpose.id
        purpose.destroy

        post item_usage_records_path(item), params: usage_params(item_purpose_id: purpose_id)

        expect(response).to have_http_status(:unprocessable_content)
      end

      it "UUID の形でない用途 id でも 500 にならず 422" do
        post item_usage_records_path(item), params: usage_params(item_purpose_id: "99999999999999999999")

        expect(response).to have_http_status(:unprocessable_content)
      end

      it "UUID の形でないロット id でも 500 にならず 422" do
        post item_usage_records_path(item), params: usage_params(lot_id: "99999999999999999999")

        expect(response).to have_http_status(:unprocessable_content)
      end

      it "他の品目のロットを指定すると 422 で、そのロットも減らない" do
        other_lot = create(:lot, item: create(:item), initial_quantity: 5)

        post item_usage_records_path(item), params: usage_params(lot_id: other_lot.id)

        expect(response).to have_http_status(:unprocessable_content)
        expect(other_lot.reload.remaining_quantity).to eq 5
      end

      it "usage_record キーが無ければ 400 (500 にしない)" do
        post item_usage_records_path(item), params: { quantity: "1" }

        expect(response).to have_http_status(:bad_request)
      end
    end

    describe "フォームから変更できない項目" do
      it "品目は URL で決まる (usage_record[item_id] は効かない)" do
        other = create(:item)
        create(:lot, item: other, initial_quantity: 5)

        post item_usage_records_path(item), params: usage_params(item_id: other.id)

        expect(UsageRecord.order(:id).last.item).to eq item
        expect(other.reload.current_quantity).to eq 5
      end

      it "記録者は渡しても変わらない" do
        other = create(:user)

        post item_usage_records_path(item), params: usage_params(user_id: other.id)

        expect(UsageRecord.order(:id).last.user).to eq user
      end
    end
  end

  describe "GET /usage_records/:id/edit (編集フォーム)" do
    it "開ける" do
      create(:lot, item: item, initial_quantity: 10)
      usage = create(:usage_record, item: item, user: user, quantity: 3)

      get edit_usage_record_path(usage)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.at("input[name='usage_record[quantity]']")[:value]).to eq "3"
    end

    it "存在しない記録は 404" do
      get edit_usage_record_path(id: 0)

      expect(response).to have_http_status(:not_found)
    end

    # 編集は movement を作り直すので、選び直さない限り今のロットを優先する
    it "ロットの選択の既定は「変更しない」" do
      expiring = create(:item, :tracks_expiry, name: "たまご")
      create(:lot, item: expiring, initial_quantity: 5, expires_on: Date.current + 7)
      usage = create(:usage_record, item: expiring, user: user, quantity: 1)

      get edit_usage_record_path(usage)

      expect(response.parsed_body.at("select[name='usage_record[lot_id]'] option").text)
        .to include "変更しない"
    end

    # アーカイブ済みの用途が付いた記録を編集しても、用途が外れないようにする
    it "アーカイブ済みの用途も選択肢に残る" do
      purposes_item = create(:item, name: "単 3 電池", tracks_purposes: true)
      purpose = create(:item_purpose, item: purposes_item, name: "むかしの用途")
      usage = create(:usage_record, item: purposes_item, user: user, item_purpose: purpose)
      purpose.archive!

      get edit_usage_record_path(usage)

      expect(response.body).to include "むかしの用途"
      expect(response.body).to include "アーカイブ済み"
      expect(response.parsed_body.at("input[name='usage_record[item_purpose_id]'][value='#{purpose.id}']"))
        .to be_present
    end
  end

  describe "PATCH /usage_records/:id (編集)" do
    let!(:lot) { create(:lot, item: item, initial_quantity: 10) }
    let(:usage) { create(:usage_record, item: item, user: user, quantity: 3) }

    it "数量を編集すると在庫が再計算される" do
      patch usage_record_path(usage), params: usage_params(quantity: "5")

      expect(usage.reload.quantity).to eq 5
      expect(item.reload.current_quantity).to eq 5
      expect(response).to redirect_to item_path(item)
    end

    it "使用日を編集すると movement の日付も直る" do
      patch usage_record_path(usage), params: usage_params(quantity: "3", used_on: (Date.current - 2).to_s)

      expect(usage.reload.stock_movements.pluck(:occurred_on).uniq).to eq [ Date.current - 2 ]
      expect(item.reload.last_consumed_on).to eq Date.current - 2
    end

    it "未来の日付には編集できず 422" do
      travel_to Time.current.change(hour: 0, min: 10) do
        patch usage_record_path(usage), params: usage_params(quantity: "3", used_on: (Date.current + 1).to_s)
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(item.reload.current_quantity).to eq 7
    end

    it "数量を 0 にはできず 422" do
      patch usage_record_path(usage), params: usage_params(quantity: "0")

      expect(response).to have_http_status(:unprocessable_content)
      expect(usage.reload.quantity).to eq 3
    end

    it "品目は変えられない" do
      other = create(:item)

      patch usage_record_path(usage), params: usage_params(quantity: "3", item_id: other.id)

      expect(usage.reload.item).to eq item
      expect(other.reload.current_quantity).to eq 0
    end

    it "記録者は変えられない" do
      other = create(:user)

      patch usage_record_path(usage), params: usage_params(quantity: "3", user_id: other.id)

      expect(usage.reload.user).to eq user
    end

    it "usage_record キーが無ければ 400 (500 にしない)" do
      patch usage_record_path(usage), params: { quantity: "5" }

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "DELETE /usage_records/:id (削除・取り消し)" do
    let!(:lot) { create(:lot, item: item, initial_quantity: 10) }
    let!(:usage) { create(:usage_record, item: item, user: user, quantity: 3) }

    it "削除すると在庫が戻る" do
      expect { delete usage_record_path(usage) }
        .to change { UsageRecord.count }.by(-1)
        .and change { StockMovement.count }.by(-1)

      expect(item.reload.current_quantity).to eq 10
    end

    # ワンタップ使用の「取り消し」は一覧から押されるので、押した画面に戻す
    it "押した画面 (品目一覧) に戻る" do
      delete usage_record_path(usage), headers: { "HTTP_REFERER" => items_url }

      expect(response).to redirect_to items_url
      follow_redirect!
      expect(response.body).to include "取り消しました"
    end

    it "Referer が無ければ品目詳細に戻る" do
      delete usage_record_path(usage)

      expect(response).to redirect_to item_path(item)
    end

    # 削除した記録の編集画面に戻すと 404 になる
    it "編集画面から削除したときは品目詳細に戻る" do
      delete usage_record_path(usage),
        headers: { "HTTP_REFERER" => edit_usage_record_url(usage) }

      expect(response).to redirect_to item_path(item)
    end

    # 検証エラーで再描画された編集画面の URL は /usage_records/:id (GET のルートは無い)
    it "検証エラーで再描画された編集画面から削除しても品目詳細に戻る" do
      delete usage_record_path(usage), headers: { "HTTP_REFERER" => usage_record_url(usage) }

      expect(response).to redirect_to item_path(item)
    end

    # /usage_records/5 と /usage_records/50 を取り違えない
    it "別の記録の画面から削除したときは、その画面に戻る" do
      other = create(:usage_record, item: item, user: user, quantity: 1)

      delete usage_record_path(usage), headers: { "HTTP_REFERER" => edit_usage_record_url(other) }

      expect(response).to redirect_to edit_usage_record_url(other)
    end

    # 2 台で同時に「取り消し」を押しても 404 を見せない
    it "すでに取り消されている記録の削除は、その旨を知らせて一覧に戻る" do
      Stock::DeleteMovement.call(UsageRecord.find(usage.id))

      delete usage_record_path(usage), headers: { "HTTP_REFERER" => items_url }

      expect(response).to redirect_to items_url
      follow_redirect!
      expect(response.body).to include "すでに取り消されています"
    end

    it "Referer が無ければ品目一覧に戻る (すでに取り消されているとき)" do
      Stock::DeleteMovement.call(UsageRecord.find(usage.id))

      delete usage_record_path(usage)

      expect(response).to redirect_to items_path
    end

    it "外部サイトの Referer は無視して品目詳細に戻る" do
      delete usage_record_path(usage), headers: { "HTTP_REFERER" => "https://example.net/" }

      expect(response).to redirect_to item_path(item)
    end

    # 取り消しは 2 台で同時に押されるので、無い記録でも 404 は見せない
    it "存在しない記録の削除は 404 にせず、取り消し済みとして知らせる" do
      delete usage_record_path(id: 0)

      expect(response).to redirect_to items_path
      follow_redirect!
      expect(response.body).to include "すでに取り消されています"
    end
  end
end
