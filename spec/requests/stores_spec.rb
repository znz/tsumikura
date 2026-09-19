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
end
