require "rails_helper"

RSpec.describe "店舗", type: :request do
  let(:user) { create(:user) }

  before { sign_in user }

  it "名前順に一覧できる" do
    last = create(:store, name: "やおや")
    first = create(:store, name: "あおぞらスーパー")

    get stores_path

    expect(response).to have_http_status(:ok)
    list = rendered_list("店舗一覧")
    expect(list.index(first.name)).to be < list.index(last.name)
  end

  it "メモつきで追加できる" do
    expect {
      post stores_path, params: { store: { name: "あおぞらスーパー", note: "駅前。日曜は混む" } }
    }.to change { Store.count }.by(1)

    expect(Store.order(:id).last.note).to eq "駅前。日曜は混む"
    expect(response).to redirect_to stores_path
  end

  it "名前が空なら追加できない" do
    expect {
      post stores_path, params: { store: { name: "" } }
    }.not_to change { Store.count }

    expect(response).to have_http_status(:unprocessable_content)
  end

  it "同じ名前は追加できない" do
    create(:store, name: "あおぞらスーパー")

    expect {
      post stores_path, params: { store: { name: "あおぞらスーパー" } }
    }.not_to change { Store.count }

    expect(response).to have_http_status(:unprocessable_content)
  end

  it "名前とメモを変更できる" do
    store = create(:store, name: "やおや")

    patch store_path(store), params: { store: { name: "やおや (移転後)", note: "2 号店" } }

    store.reload
    expect(store.name).to eq "やおや (移転後)"
    expect(store.note).to eq "2 号店"
  end

  it "削除できる" do
    store = create(:store)

    expect { delete store_path(store) }.to change { Store.count }.by(-1)

    expect(response).to redirect_to stores_path
  end

  # 削除は nullify。購入の記録は消えず、店舗だけが外れる
  describe "削除と購入の記録" do
    it "削除しても購入の記録は消えず、店舗だけが外れる" do
      store = create(:store)
      item = create(:item)
      lot = create(:lot, item: item, store: store, initial_quantity: 12)

      expect { delete store_path(store) }.not_to change { Lot.count }

      expect(lot.reload.store_id).to be_nil
      expect(item.reload.current_quantity).to eq 12
    end

    it "削除後に「n 件の購入の記録から外れました」と知らせる" do
      store = create(:store)
      create(:lot, store: store)
      create(:lot, store: store)

      delete store_path(store)
      follow_redirect!

      expect(response.body).to include "2 件の購入の記録から店舗が外れました"
    end

    # 確認ダイアログ (JS) だけに頼らず、外れる件数をサーバ側で出す
    it "削除前に「n 件の購入の記録から外れます」を編集画面に出す" do
      store = create(:store)
      create(:lot, store: store)

      get edit_store_path(store)

      expect(response.body).to include "1 件の購入の記録から店舗が外れます"
    end

    it "使われていない店舗の編集画面では 0 件と出る" do
      get edit_store_path(create(:store))

      expect(response.body).to include "0 件の購入の記録から店舗が外れます"
    end
  end
end
