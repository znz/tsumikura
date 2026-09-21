require "rails_helper"

RSpec.describe "買い物リストの行", type: :request do
  before { freeze_time }

  let(:user) { create(:user, name: "おかあさん") }

  before { sign_in user }

  # 最低在庫数を下回っていれば urgent (docs/spec/02-forecast.md 6 節)
  def urgent_item(name: "ティッシュ", **attributes)
    create(:item, name: name, minimum_quantity: 5, **attributes).tap { |item| stock_up(item, 3) }
  end

  describe "POST /shopping_list_items (チェック)" do
    it "自動で並んでいる行をチェックすると、そのとき初めて行が作られる" do
      item = urgent_item

      expect {
        post shopping_list_items_path,
          params: { shopping_list_item: { item_id: item.id, checked: "true" } }
      }.to change(ShoppingListItem, :count).by(1)

      # JS が無いときに先頭に戻されないよう、操作した行へのアンカーを付ける
      expect(response).to redirect_to shopping_list_path(anchor: "shopping_list_row_item_#{item.id}")
      entry = ShoppingListItem.sole
      expect(entry.item).to eq item
      expect(entry).to be_checked
      expect(entry.added_by).to eq user
      expect(entry).not_to be_added_manually
    end

    it "同じ品目を 2 回チェックしても行は増えず、チェック時刻も動かない" do
      item = urgent_item
      post shopping_list_items_path,
        params: { shopping_list_item: { item_id: item.id, checked: "true" } }
      checked_at = ShoppingListItem.sole.checked_at

      travel 1.minute
      expect {
        post shopping_list_items_path,
          params: { shopping_list_item: { item_id: item.id, checked: "true" } }
      }.not_to change(ShoppingListItem, :count)

      expect(ShoppingListItem.sole.checked_at).to eq checked_at
    end

    it "品目を手動で買い物リストに追加できる (判定が ok でも並ぶ)" do
      item = stock_up(create(:item, name: "よびのでんち", minimum_quantity: 1), 10).item

      post shopping_list_items_path,
        params: { shopping_list_item: { item_id: item.id, manual: "true" } }

      expect(ShoppingListItem.sole).to be_added_manually
      expect(flash[:notice]).to include "買い物リストに追加しました"

      get shopping_list_path
      expect(rendered_list("手動で追加した品目")).to include "よびのでんち"
    end

    it "すでに自動で並んでいる品目を手動で足しても、すでにある旨を伝える" do
      item = urgent_item

      post shopping_list_items_path,
        params: { shopping_list_item: { item_id: item.id, manual: "true" } }

      expect(flash[:notice]).to include "すでに買い物リストにあります"
    end

    # 数量の上書きだけが残った行やスヌーズ中の行は一覧に出ていないので、
    # 「すでにあります」と言われても何のことか分からない
    it "一覧に出ていなかった品目を手動で足したら「追加しました」と伝える" do
      item = urgent_item
      create(:shopping_list_item, item: item, added_by: user, snoozed_until: Date.current + 3)

      post shopping_list_items_path,
        params: { shopping_list_item: { item_id: item.id, manual: "true" } }

      expect(flash[:notice]).to include "買い物リストに追加しました"
    end

    it "手動で足すとスヌーズは解除される (手で足したのに畳まれたまま、を避ける)" do
      item = urgent_item
      entry = create(:shopping_list_item, item: item, added_by: user, snoozed_until: Date.current + 3)

      post shopping_list_items_path,
        params: { shopping_list_item: { item_id: item.id, manual: "true" } }

      expect(entry.reload.snoozed_until).to be_nil
      expect(entry).to be_added_manually
    end

    # 同じ品目の行を 2 人が同時に作ると、部分一意 index か uniqueness の検証で片方が負ける。
    # 負けた側の操作を黙って捨てない
    it "行の作成が競合しても、要求した操作は相手の行に反映される" do
      item = urgent_item
      existing = create(:shopping_list_item, item: item, added_by: create(:user), quantity: 3)
      # 「まだ行が無い」と見えた状態を作る
      allow(ShoppingListItem).to receive(:find_or_initialize_by).with(item_id: item.id)
        .and_return(ShoppingListItem.new(item_id: item.id))

      expect {
        post shopping_list_items_path,
          params: { shopping_list_item: { item_id: item.id, checked: "true" } }
      }.not_to change(ShoppingListItem, :count)

      expect(existing.reload).to be_checked
      expect(existing.quantity).to eq 3   # 相手の入力は壊さない
    end

    # 作ってすぐ片づける行を「追加しました」と言わない
    it "操作も手動の指定も無い POST は 400 で、行を作らない" do
      item = urgent_item

      expect {
        post shopping_list_items_path, params: { shopping_list_item: { item_id: item.id } }
      }.not_to change(ShoppingListItem, :count)

      expect(response).to have_http_status(:bad_request)
    end

    # 壊れた値 (uuid に cast できない) と、形は正しいが存在しない UUID の両方
    it "存在しない品目には行を作らない (404 でも 500 でもなく案内して戻す)" do
      [ "0", nonexistent_uuid ].each do |item_id|
        expect {
          post shopping_list_items_path, params: { shopping_list_item: { item_id: item_id, checked: "true" } }
        }.not_to change(ShoppingListItem, :count)

        expect(response).to redirect_to shopping_list_path
      end
    end

    it "UUID の形でない品目 id でも 500 にしない" do
      post shopping_list_items_path,
        params: { shopping_list_item: { item_id: "9" * 30, checked: "true" } }

      expect(response).to redirect_to shopping_list_path
    end

    it "アーカイブ済みの品目は追加できない" do
      item = urgent_item
      item.archive!

      expect {
        post shopping_list_items_path,
          params: { shopping_list_item: { item_id: item.id, manual: "true" } }
      }.not_to change(ShoppingListItem, :count)
    end

    it "壊れたパラメータでは 400 になる (500 にしない)" do
      post shopping_list_items_path, params: { shopping_list_item: "こわれている" }

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "POST /shopping_list_items (自由入力)" do
    it "自由入力の行を追加できる" do
      expect {
        post shopping_list_items_path, params: { shopping_list_item: { free_text: "　はがき " } }
      }.to change(ShoppingListItem, :count).by(1)

      entry = ShoppingListItem.sole
      expect(entry.free_text).to eq "はがき"
      expect(entry.item).to be_nil
      expect(entry).to be_added_manually
    end

    it "空の自由入力は 422 で、入力欄に戻って理由が出る" do
      expect {
        post shopping_list_items_path, params: { shopping_list_item: { free_text: "  " } }
      }.not_to change(ShoppingListItem, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include "自由入力"
    end

    it "長すぎる自由入力は 422 で、入力が消えない" do
      too_long = "あ" * (ShoppingListItem::MAX_FREE_TEXT_LENGTH + 1)

      post shopping_list_items_path, params: { shopping_list_item: { free_text: too_long } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.at("#shopping_list_item_free_text")[:value]).to eq too_long
    end
  end

  describe "PATCH /shopping_list_items/:id" do
    let(:item) { urgent_item }
    let!(:entry) { create(:shopping_list_item, item: item, added_by: user) }

    it "チェックを外せる" do
      entry.update!(checked_at: Time.current, quantity: 2)

      patch shopping_list_item_path(entry), params: { shopping_list_item: { checked: "false" } }

      expect(entry.reload).not_to be_checked
    end

    it "チェックを外して何も残らなくなった行は消える (導出でまた並ぶ)" do
      entry.update!(checked_at: Time.current)

      expect {
        patch shopping_list_item_path(entry), params: { shopping_list_item: { checked: "false" } }
      }.to change(ShoppingListItem, :count).by(-1)

      get shopping_list_path
      expect(rendered_list("要購入の品目")).to include item.name
    end

    # メモリ上の値で判断して destroy すると、自分が読んだあとに他の人が付けた
    # チェックごと消してしまう。片づけは条件付きの DELETE で行う
    it "片づけの直前に他の人がチェックし直したら、その行は消さない" do
      entry.update!(checked_at: Time.current)
      allow_any_instance_of(ShoppingListItem).to receive(:save).and_wrap_original do |original, *args|
        saved = original.call(*args)
        ShoppingListItem.where(id: entry.id).update_all(checked_at: Time.current)
        saved
      end

      patch shopping_list_item_path(entry), params: { shopping_list_item: { checked: "false" } }

      expect(ShoppingListItem.exists?(entry.id)).to be true
      expect(entry.reload).to be_checked
    end

    it "古い画面から同じ状態を 2 回送っても反転しない (トグルにしない)" do
      patch shopping_list_item_path(entry), params: { shopping_list_item: { checked: "true" } }
      patch shopping_list_item_path(ShoppingListItem.sole), params: { shopping_list_item: { checked: "true" } }

      expect(ShoppingListItem.sole).to be_checked
    end

    it "希望数量を上書きできる" do
      patch shopping_list_item_path(entry), params: { shopping_list_item: { quantity: "4" } }

      expect(entry.reload.quantity).to eq 4
    end

    it "希望数量を空にすると上書きが外れる" do
      entry.update!(quantity: 4, checked_at: Time.current)

      patch shopping_list_item_path(entry), params: { shopping_list_item: { quantity: "" } }

      expect(entry.reload.quantity).to be_nil
    end

    it "数字でない希望数量は 422 で、在庫も行も壊さない" do
      patch shopping_list_item_path(entry), params: { shopping_list_item: { quantity: "2abc" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(entry.reload.quantity).to be_nil
    end

    it "スヌーズすると一覧から外れ、解除すると戻る" do
      patch shopping_list_item_path(entry), params: { shopping_list_item: { snoozed: "true" } }

      expect(entry.reload.snoozed_until).to eq Date.current + ShoppingListItem::SNOOZE_DAYS
      get shopping_list_path
      expect(rendered_list("要購入の品目")).not_to include item.name

      patch shopping_list_item_path(entry), params: { shopping_list_item: { snoozed: "false" } }
      get shopping_list_path
      expect(rendered_list("要購入の品目")).to include item.name
    end

    it "checked_at や added_by は入力から差し替えられない (mass assignment の遮断)" do
      other = create(:user)

      patch shopping_list_item_path(entry), params: {
        shopping_list_item: { checked: "true", checked_at: 3.days.ago.to_s, added_by_id: other.id }
      }

      expect(entry.reload.checked_at).to eq Time.current
      expect(entry.added_by).to eq user
    end

    it "まとめ購入や掃除で消えた行への操作は 404 にせず、やり直せることを伝えて一覧へ戻す" do
      id = entry.id
      entry.destroy!

      patch shopping_list_item_path(id), params: { shopping_list_item: { checked: "true" } }

      expect(response).to redirect_to shopping_list_path
      expect(flash[:alert]).to include "もう一度操作してください"
    end
  end

  describe "DELETE /shopping_list_items/:id" do
    it "手動で足した行を消せる" do
      entry = create(:shopping_list_item, :free_text, added_by: user)

      expect { delete shopping_list_item_path(entry) }.to change(ShoppingListItem, :count).by(-1)

      expect(response).to redirect_to shopping_list_path
    end

    it "すでに消えている行を消しても 404 にしない" do
      entry = create(:shopping_list_item, :free_text, added_by: user)
      id = entry.id
      entry.destroy!

      delete shopping_list_item_path(id)

      expect(response).to redirect_to shopping_list_path
      expect(flash[:alert]).to be_present
    end
  end
end
