require "rails_helper"

RSpec.describe "保管場所", type: :request do
  let(:user) { create(:user) }

  before { sign_in user }

  it "一覧できる" do
    storage_location = create(:storage_location, name: "洗面所")

    get storage_locations_path

    expect(response).to have_http_status(:ok)
    expect(rendered_list("保管場所一覧")).to include storage_location.name
  end

  it "追加できる" do
    expect {
      post storage_locations_path, params: { storage_location: { name: "洗面所" } }
    }.to change { StorageLocation.count }.by(1)

    expect(response).to redirect_to storage_locations_path
  end

  it "名前が空なら追加できない" do
    expect {
      post storage_locations_path, params: { storage_location: { name: "" } }
    }.not_to change { StorageLocation.count }

    expect(response).to have_http_status(:unprocessable_content)
  end

  it "名前を変更できる" do
    storage_location = create(:storage_location, name: "洗面所")

    patch storage_location_path(storage_location), params: { storage_location: { name: "脱衣所" } }

    expect(storage_location.reload.name).to eq "脱衣所"
  end

  it "並べ替えできる" do
    first = create(:storage_location)
    second = create(:storage_location)

    patch storage_location_position_path(second), params: { direction: "up" }

    expect(StorageLocation.ordered.to_a).to eq [ second, first ]
  end

  it "削除しても品目は消えず、保管場所だけが外れる" do
    storage_location = create(:storage_location)
    item = create(:item, storage_location: storage_location)

    expect { delete storage_location_path(storage_location) }.not_to change { Item.count }

    expect(item.reload.storage_location_id).to be_nil
    expect(StorageLocation.exists?(storage_location.id)).to be false
  end

  it "削除すると外れた品目の件数を知らせる" do
    storage_location = create(:storage_location)
    create(:item, storage_location: storage_location)

    delete storage_location_path(storage_location)

    expect(flash[:notice]).to include "1 件"
  end

  it "削除前に、外れる品目の件数を編集画面で知らせる" do
    storage_location = create(:storage_location)
    create(:item, storage_location: storage_location)

    get edit_storage_location_path(storage_location)

    expect(response.body).to include "1 件の品目から保管場所が外れます"
  end
end
