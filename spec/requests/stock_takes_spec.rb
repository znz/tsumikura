require "rails_helper"

RSpec.describe "棚卸", type: :request do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:user) { create(:user) }
  let(:kitchen) { create(:storage_location, name: "台所") }
  let(:item) { create(:item, name: "ラップ", unit: "本", storage_location: kitchen) }

  before { sign_in user }

  def draft(attributes = {})
    create(:stock_take, { user: user, storage_location: kitchen }.merge(attributes))
  end

  describe "GET /stock_takes" do
    it "下書きと確定済みが分かれて並ぶ" do
      draft
      create(:stock_take, :finalized, storage_location: create(:storage_location, name: "洗面所"))

      get stock_takes_path

      expect(rendered_list("下書きの棚卸一覧")).to include "台所"
      expect(rendered_list("確定済みの棚卸一覧")).to include "洗面所"
    end
  end

  describe "POST /stock_takes" do
    it "棚卸を作ると入力画面に進む" do
      expect {
        post stock_takes_path,
          params: { stock_take: { counted_on: Date.current.to_s, storage_location_id: kitchen.id } }
      }.to change { StockTake.count }.by(1)

      stock_take = StockTake.sole
      expect(stock_take.user).to eq user
      expect(stock_take.finalized_at).to be_nil
      expect(response).to redirect_to edit_stock_take_path(stock_take)
    end

    it "保管場所を選ばなければ全体の棚卸になる" do
      post stock_takes_path, params: { stock_take: { counted_on: Date.current.to_s } }

      expect(StockTake.sole.storage_location).to be_nil
    end

    # 記録者・確定日時はフォームから変更できない (mass assignment の遮断)
    it "user_id / finalized_at を送っても無視される" do
      other = create(:user)

      post stock_takes_path, params: { stock_take: {
        counted_on: Date.current.to_s, user_id: other.id, finalized_at: Time.current.to_s
      } }

      expect(StockTake.sole.user).to eq user
      expect(StockTake.sole.finalized_at).to be_nil
    end

    it "未来の日付 / 削除済みの保管場所 id は 422 (500 にしない)" do
      post stock_takes_path, params: { stock_take: { counted_on: (Date.current + 1).to_s } }
      expect(response).to have_http_status(:unprocessable_content)

      post stock_takes_path,
        params: { stock_take: { counted_on: Date.current.to_s, storage_location_id: 0 } }
      expect(response).to have_http_status(:unprocessable_content)

      # 壊れた値とは経路が違う (こちらは cast が通って関連が nil になる)
      post stock_takes_path,
        params: { stock_take: { counted_on: Date.current.to_s, storage_location_id: nonexistent_uuid } }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "stock_take キーが無ければ 400 (500 にしない)" do
      post stock_takes_path, params: {}

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "GET /stock_takes/:id/edit" do
    it "その保管場所の品目だけが並び、記録在庫が出る" do
      create(:lot, item: item, initial_quantity: 3)
      create(:item, name: "歯ブラシ", storage_location: create(:storage_location, name: "洗面所"))
      create(:item, :archived, name: "むかしの品目", storage_location: kitchen)

      get edit_stock_take_path(draft)

      expect(rendered_list("棚卸の品目一覧")).to include "ラップ"
      expect(rendered_list("棚卸の品目一覧")).not_to include "歯ブラシ"
      expect(rendered_list("棚卸の品目一覧")).not_to include "むかしの品目"
      expect(rendered_list("棚卸の品目一覧")).to include "記録在庫 3"
    end

    it "期限を管理してロットが 2 件以上ある品目だけロット別に数えられる" do
      expiring = create(:item, :tracks_expiry, name: "たまご", storage_location: kitchen)
      create(:lot, item: expiring, initial_quantity: 6, expires_on: Date.current + 1)
      create(:lot, item: expiring, initial_quantity: 6, expires_on: Date.current + 30)
      create(:lot, item: item, initial_quantity: 3)

      get edit_stock_take_path(draft)

      expect(rendered_list("棚卸の品目一覧")).to include "ロット別に数える"
      expect(response.body).to include "counts[#{expiring.id}][lots]"
      expect(response.body).not_to include "counts[#{item.id}][lots]"
    end

    it "ロットが 1 件だけならロット別の入力は出ない" do
      expiring = create(:item, :tracks_expiry, name: "たまご", storage_location: kitchen)
      create(:lot, item: expiring, initial_quantity: 6, expires_on: Date.current + 1)

      get edit_stock_take_path(draft)

      expect(response.body).not_to include "ロット別に数える"
    end

    # 欄が消えると、その明細を直すことも確かめることもできなくなる
    it "すでにロット別に数えたロットは、使い切られても欄を出し続ける" do
      stock_take = draft
      expiring = create(:item, :tracks_expiry, name: "たまご", storage_location: kitchen)
      near = create(:lot, item: expiring, initial_quantity: 6, expires_on: Date.current + 1)
      create(:lot, item: expiring, initial_quantity: 6, expires_on: Date.current + 30)
      patch stock_take_path(stock_take),
        params: { counts: { expiring.id.to_s => { lots: { near.id.to_s => "4" } } } }
      Stock::RecordUsage.call(item: expiring, user: user,
        attributes: { quantity: 6, used_on: Date.current, lot_id: near.id })

      get edit_stock_take_path(stock_take)

      expect(response.body).to include %(name="counts[#{expiring.id}][lots][#{near.id}]")
      # 入力済みなので畳まずに開いておく
      expect(response.parsed_body.at("details[open]")).to be_present
    end

    it "確定済みの棚卸は編集できない (404)" do
      get edit_stock_take_path(create(:stock_take, :finalized))

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /stock_takes/:id" do
    let(:stock_take) { draft }

    before { create(:lot, item: item, initial_quantity: 3) }

    it "実数を入れると明細が作られ、在庫はまだ変わらない" do
      expect {
        patch stock_take_path(stock_take), params: { counts: { item.id.to_s => { total: "1" } } }
      }.to change { StockTakeEntry.count }.by(1)

      expect(StockMovement.where(stock_take_entry_id: StockTakeEntry.sole.id)).to be_empty

      entry = StockTakeEntry.sole
      expect(entry.counted_quantity).to eq 1
      expect(entry.expected_quantity).to eq 3
      expect(entry.difference).to eq(-2)
      expect(item.reload.current_quantity).to eq 3
      expect(response).to redirect_to stock_take_path(stock_take)
    end

    it "未入力の品目には明細を作らない" do
      expect {
        patch stock_take_path(stock_take), params: { counts: { item.id.to_s => { total: "" } } }
      }.not_to change { StockTakeEntry.count }
    end

    it "入れた実数を空で送り直すと明細が消える" do
      patch stock_take_path(stock_take), params: { counts: { item.id.to_s => { total: "1" } } }

      expect {
        patch stock_take_path(stock_take),
          params: { counts: { item.id.to_s => { total: "", was: "1" } } }
      }.to change { StockTakeEntry.count }.by(-1)
    end

    # フォームは全品目を送るので、そのまま書くと別のタブ・別の人が先に入れた実数を
    # 空欄で上書き (削除) してしまう
    it "古い画面を送り直しても、あとから入った実数は消えない" do
      other = create(:item, name: "アルミホイル", storage_location: kitchen)
      create(:lot, item: other, initial_quantity: 4)
      # A さんがラップを数えて保存
      patch stock_take_path(stock_take), params: { counts: { item.id.to_s => { total: "1" } } }

      # B さんは両方とも空の画面を開いたまま、アルミホイルだけ入れて保存
      patch stock_take_path(stock_take), params: { counts: {
        item.id.to_s => { total: "", was: "" }, other.id.to_s => { total: "2", was: "" }
      } }

      expect(stock_take.stock_take_entries.count).to eq 2
      expect(stock_take.stock_take_entries.find_by(item_id: item.id).counted_quantity).to eq 1
    end

    it "入力欄には元の値が hidden で添えられる" do
      patch stock_take_path(stock_take), params: { counts: { item.id.to_s => { total: "1" } } }

      get edit_stock_take_path(stock_take)

      expect(response.body).to include %(name="counts[#{item.id}][was]")
      expect(response.parsed_body.at(%(input[name="counts[#{item.id}][was]"]))[:value]).to eq "1"
    end

    it "途中保存では入力画面に戻る" do
      patch stock_take_path(stock_take),
        params: { counts: { item.id.to_s => { total: "1" } }, continue: "1" }

      expect(response).to redirect_to edit_stock_take_path(stock_take)
      expect(flash[:notice]).to include "途中まで保存しました"
    end

    it "ロット別に入れると合計の入力は使われない" do
      expiring = create(:item, :tracks_expiry, name: "たまご", storage_location: kitchen)
      near = create(:lot, item: expiring, initial_quantity: 6, expires_on: Date.current + 1)
      create(:lot, item: expiring, initial_quantity: 6, expires_on: Date.current + 30)

      patch stock_take_path(stock_take), params: { counts: {
        expiring.id.to_s => { total: "99", lots: { near.id.to_s => "4" } }
      } }

      entries = stock_take.stock_take_entries.where(item_id: expiring.id)
      expect(entries.count).to eq 1
      expect(entries.sole.lot).to eq near
      expect(entries.sole.counted_quantity).to eq 4
    end

    it "他の保管場所の品目の実数は無視する" do
      elsewhere = create(:item, name: "歯ブラシ", storage_location: create(:storage_location))

      expect {
        patch stock_take_path(stock_take), params: { counts: { elsewhere.id.to_s => { total: "3" } } }
      }.not_to change { StockTakeEntry.count }
    end

    it "他の品目のロット id は無視する" do
      other_lot = create(:lot, item: create(:item), initial_quantity: 5)

      patch stock_take_path(stock_take), params: { counts: {
        item.id.to_s => { lots: { other_lot.id.to_s => "2" } }
      } }

      expect(StockTakeEntry.where.not(lot_id: nil)).to be_empty
    end

    it "数字でない実数 / マイナス / 上限超えは 422 で、入力は画面に残る (500 にしない)" do
      patch stock_take_path(stock_take), params: { counts: { item.id.to_s => { total: "-1" } } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(StockTakeEntry.count).to eq 0
      expect(response.body).to include "value=\"-1\""
    end

    it "4 バイト整数をはみ出す実数でも 422 (500 にしない)" do
      patch stock_take_path(stock_take), params: { counts: { item.id.to_s => { total: "3000000000" } } }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "壊れた counts (配列・文字列) でも 500 にしない" do
      patch stock_take_path(stock_take), params: { counts: "abc" }
      expect(response).to redirect_to stock_take_path(stock_take)

      patch stock_take_path(stock_take), params: { counts: { item.id.to_s => "abc" } }
      expect(response).to redirect_to stock_take_path(stock_take)
    end

    it "確定済みの棚卸は更新できない (404)" do
      patch stock_take_path(create(:stock_take, :finalized)), params: { counts: {} }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /stock_takes/:id (確認画面)" do
    let(:stock_take) { draft }

    before { create(:lot, item: item, initial_quantity: 3) }

    it "差分サマリ (増 n 件 / 減 n 件) と明細が出る" do
      patch stock_take_path(stock_take), params: { counts: { item.id.to_s => { total: "1" } } }

      get stock_take_path(stock_take)

      expect(response.body).to include "差分のまとめ"
      expect(rendered_list("棚卸の明細一覧")).to include "ラップ"
      expect(rendered_list("棚卸の明細一覧")).to include "−2"
      expect(response.body).to include "この内容で確定する"
    end

    it "確定済みなら確定ボタンを出さない" do
      get stock_take_path(create(:stock_take, :finalized))

      expect(response.body).not_to include "この内容で確定する"
      expect(response.body).to include "確定済みの棚卸は編集・削除できません"
    end

    # 在庫は動かないのに棚卸日だけが進み、以降の記録すべてに警告が出てしまう
    it "1 件も数えていなければ確定ボタンを出さない" do
      get stock_take_path(stock_take)

      expect(response.body).not_to include "この内容で確定する"
      expect(response.body).to include "まだ 1 件も数えていないので確定できません"
    end

    # 数えてから確定までに使用・購入があると、確定は「今の記録在庫」との差を取る。
    # 確認した数字と適用される数字を食い違わせない
    describe "数えたあとに在庫が動いたとき" do
      before do
        patch stock_take_path(stock_take), params: { counts: { item.id.to_s => { total: "1" } } }
        Stock::RecordUsage.call(item: item, user: user,
          attributes: { quantity: 1, used_on: Date.current })
      end

      it "確定で適用される差分 (今の記録在庫との差) を出す" do
        get stock_take_path(stock_take)

        expect(rendered_list("棚卸の明細一覧")).to include "記録 2 → 実数 1"
        expect(rendered_list("棚卸の明細一覧")).to include "−1"
        expect(rendered_list("棚卸の明細一覧")).not_to include "−2"
      end

      it "在庫が動いたことを明細に知らせる" do
        get stock_take_path(stock_take)

        expect(rendered_list("棚卸の明細一覧")).to include "数えたあとに在庫の記録が動いています"
        expect(rendered_list("棚卸の明細一覧")).to include "(3 → 2)"
      end
    end

    it "差分サマリも確定で適用される差分で数える" do
      # 記録 3 のときに実数 2 と数え (保存時の差分は −1)、そのあと 1 使うと
      # 記録 2 = 実数 2 になるので、確定では差分 0 (増えても減ってもいない)
      patch stock_take_path(stock_take), params: { counts: { item.id.to_s => { total: "2" } } }
      Stock::RecordUsage.call(item: item, user: user,
        attributes: { quantity: 1, used_on: Date.current })

      get stock_take_path(stock_take)

      summary = response.parsed_body.at("section[aria-label='差分のまとめ']").text
      expect(summary.scan(/\d+ 件/)).to eq [ "0 件", "0 件", "1 件" ]
    end

    # 打ち間違い (12 を 1 と入れるなど) は消費として予測に残り続ける
    it "大きく減る差分には注意の印を出す" do
      patch stock_take_path(stock_take), params: { counts: { item.id.to_s => { total: "1" } } }

      get stock_take_path(stock_take)

      expect(rendered_list("棚卸の明細一覧")).to include "大きく減っています"
    end

    it "1 個の減りには注意の印を出さない" do
      patch stock_take_path(stock_take), params: { counts: { item.id.to_s => { total: "2" } } }

      get stock_take_path(stock_take)

      expect(rendered_list("棚卸の明細一覧")).not_to include "大きく減っています"
    end
  end

  describe "POST /stock_takes/:id/finalization" do
    let(:stock_take) { draft }

    before do
      create(:lot, item: item, initial_quantity: 3)
      patch stock_take_path(stock_take), params: { counts: { item.id.to_s => { total: "1" } } }
    end

    it "確定すると在庫が実数に合い、差分サマリを知らせる" do
      expect { post stock_take_finalization_path(stock_take) }
        .to change { StockMovement.count }.by(1)

      expect(item.reload.current_quantity).to eq 1
      expect(stock_take.reload).to be_finalized
      expect(flash[:notice]).to include "増 0 件 / 減 1 件"
      expect(response).to redirect_to stock_take_path(stock_take)
    end

    it "確定済みをもう一度確定しようとすると 404 (在庫は二重に動かない)" do
      post stock_take_finalization_path(stock_take)

      expect { post stock_take_finalization_path(stock_take) }.not_to change { StockMovement.count }
      expect(response).to have_http_status(:not_found)
      expect(item.reload.current_quantity).to eq 1
    end

    it "台帳とキャッシュが食い違っていたら 500 にせず、その旨を知らせる" do
      item.update_column(:current_quantity, 99)

      post stock_take_finalization_path(stock_take)

      expect(response).to redirect_to stock_take_path(stock_take)
      expect(flash[:alert]).to include "確定できませんでした"
      expect(stock_take.reload.finalized_at).to be_nil
    end

    # 2 台で同時に確定ボタンを押されると、ロックの後に確定済みだと分かる
    it "ロック待ちの間に確定されていたら 500 にせず、その旨を知らせる" do
      allow(Stock::FinalizeStockTake).to receive(:call)
        .and_raise(Stock::FinalizeStockTake::AlreadyFinalized)

      post stock_take_finalization_path(stock_take)

      expect(response).to redirect_to stock_take_path(stock_take)
      expect(flash[:alert]).to include "すでに確定しています"
    end
  end

  describe "1 件も数えていない棚卸の確定" do
    it "確定できず、棚卸日も進まない" do
      stock_take = draft

      post stock_take_finalization_path(stock_take)

      expect(stock_take.reload.finalized_at).to be_nil
      expect(flash[:alert]).to include "まだ 1 件も数えていない"
    end
  end

  describe "DELETE /stock_takes/:id" do
    it "下書きは削除できる" do
      stock_take = draft

      expect { delete stock_take_path(stock_take) }.to change { StockTake.count }.by(-1)
      expect(response).to redirect_to stock_takes_path
    end

    it "確定済みは削除できない (404)" do
      stock_take = create(:stock_take, :finalized)

      expect { delete stock_take_path(stock_take) }.not_to change { StockTake.count }
      expect(response).to have_http_status(:not_found)
    end

    # 確定と削除が同時に走ると、確定済みの棚卸が消えてしまう。
    # 判定はロックの「あと」でなければ意味がない
    it "行を引いてからロックするまでに確定されていたら削除できない (404)" do
      stock_take = draft
      # ロック待ちの間に別の画面で確定された状態を作る
      # (確認をロックの前に置くと、この spec が落ちる)
      allow_any_instance_of(StockTake).to receive(:lock!).and_wrap_original do |original, *args|
        StockTake.where(id: stock_take.id).update_all(finalized_at: Time.current)
        original.call(*args)
      end

      expect { delete stock_take_path(stock_take) }.not_to change { StockTake.count }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "存在しない棚卸" do
    it "404 になる (500 にしない)" do
      get stock_take_path(id: 0)

      expect(response).to have_http_status(:not_found)
    end
  end
end
