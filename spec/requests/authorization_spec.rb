require "rails_helper"

# 品目とマスタの全アクションを表で総当たりする。
# 品目・マスタの操作は「ログインしていれば全ユーザーができる」(管理者限定ではない) ので、
# 守るべき線は「未ログインは通さない」の 1 本。アクションを足したらこの表にも足すこと。
authenticated_actions = [
  [ "品目一覧", :get, -> { items_path }, -> { {} } ],
  [ "品目詳細", :get, -> { item_path(item) }, -> { {} } ],
  [ "品目の追加フォーム", :get, -> { new_item_path }, -> { {} } ],
  [ "品目の追加", :post, -> { items_path }, -> { { item: { name: "しんき", unit: "個" } } } ],
  [ "品目の編集フォーム", :get, -> { edit_item_path(item) }, -> { {} } ],
  [ "品目の更新", :patch, -> { item_path(item) }, -> { { item: { name: "のっとり", unit: "個" } } } ],
  [ "品目のアーカイブ", :post, -> { item_archive_path(item) }, -> { {} } ],
  [ "品目の復元", :delete, -> { item_archive_path(item) }, -> { {} } ],

  [ "購入の入力フォーム", :get, -> { new_item_lot_path(item) }, -> { {} } ],
  [ "購入の記録", :post, -> { item_lots_path(item) },
    -> { { lot: { acquired_on: Date.current.to_s, initial_quantity: "1" } } } ],
  [ "購入の記録の編集フォーム", :get, -> { edit_lot_path(lot) }, -> { {} } ],
  [ "購入の記録の更新", :patch, -> { lot_path(lot) },
    -> { { lot: { acquired_on: Date.current.to_s, initial_quantity: "99" } } } ],
  [ "購入の記録の削除", :delete, -> { lot_path(lot) }, -> { {} } ],

  [ "カテゴリ一覧", :get, -> { categories_path }, -> { {} } ],
  [ "カテゴリの追加フォーム", :get, -> { new_category_path }, -> { {} } ],
  [ "カテゴリの追加", :post, -> { categories_path }, -> { { category: { name: "しんき" } } } ],
  [ "カテゴリの編集フォーム", :get, -> { edit_category_path(category) }, -> { {} } ],
  [ "カテゴリの更新", :patch, -> { category_path(category) }, -> { { category: { name: "のっとり" } } } ],
  [ "カテゴリの並べ替え", :patch, -> { category_position_path(category) }, -> { { direction: "up" } } ],
  [ "カテゴリの削除", :delete, -> { category_path(category) }, -> { {} } ],

  [ "保管場所一覧", :get, -> { storage_locations_path }, -> { {} } ],
  [ "保管場所の追加フォーム", :get, -> { new_storage_location_path }, -> { {} } ],
  [ "保管場所の追加", :post, -> { storage_locations_path }, -> { { storage_location: { name: "しんき" } } } ],
  [ "保管場所の編集フォーム", :get, -> { edit_storage_location_path(storage_location) }, -> { {} } ],
  [ "保管場所の更新", :patch, -> { storage_location_path(storage_location) },
    -> { { storage_location: { name: "のっとり" } } } ],
  [ "保管場所の並べ替え", :patch, -> { storage_location_position_path(storage_location) },
    -> { { direction: "up" } } ],
  [ "保管場所の削除", :delete, -> { storage_location_path(storage_location) }, -> { {} } ],

  [ "店舗一覧", :get, -> { stores_path }, -> { {} } ],
  [ "店舗の追加フォーム", :get, -> { new_store_path }, -> { {} } ],
  [ "店舗の追加", :post, -> { stores_path }, -> { { store: { name: "しんき" } } } ],
  [ "店舗の編集フォーム", :get, -> { edit_store_path(store) }, -> { {} } ],
  [ "店舗の更新", :patch, -> { store_path(store) }, -> { { store: { name: "のっとり" } } } ],
  [ "店舗の削除", :delete, -> { store_path(store) }, -> { {} } ]
]

RSpec.describe "品目とマスタの認可", type: :request do
  let(:item) { create(:item, name: "もとの品目") }
  let(:lot) { create(:lot, item: item, initial_quantity: 5) }
  let(:category) { create(:category, name: "もとのカテゴリ") }
  let(:storage_location) { create(:storage_location, name: "もとの保管場所") }
  let(:store) { create(:store, name: "もとの店舗") }

  # def はブロックの外側のローカル変数を閉じ込められないので let 経由で渡す
  let(:all_actions) { authenticated_actions }

  def request_action(verb, path, params)
    public_send(verb, instance_exec(&path), params: instance_exec(&params))
  end

  def request_all_actions
    all_actions.each { |_name, verb, path, params| request_action(verb, path, params) }
  end

  # 表への足し忘れを検出する。ルーティング側の定義と、表が実際に叩いているアクションを
  # 突き合わせるので、アクションを足して表に足し忘れるとここが落ちる
  it "表は品目とマスタの全ルートを網羅している" do
    target_controllers = %w[
      items items/archives lots
      categories categories/positions
      storage_locations storage_locations/positions
      stores
    ]

    defined_actions = Rails.application.routes.routes.filter_map { |route|
      controller = route.defaults[:controller]
      [ controller, route.defaults[:action] ] if target_controllers.include?(controller)
    }.uniq

    covered_actions = all_actions.map { |_name, verb, path, _params|
      recognized = Rails.application.routes.recognize_path(instance_exec(&path), method: verb)
      [ recognized[:controller], recognized[:action] ]
    }.uniq

    expect(covered_actions).to match_array(defined_actions)
  end

  describe "未ログイン" do
    authenticated_actions.each do |name, verb, path, params|
      it "#{name} はログイン画面にリダイレクトされる" do
        request_action(verb, path, params)

        expect(response).to redirect_to new_session_path
      end
    end

    it "すべて叩いてもレコードは増えない" do
      item
      lot
      category
      storage_location
      store

      expect { request_all_actions }.not_to change {
        [ Item.count, Lot.count, StockMovement.count, Category.count, StorageLocation.count, Store.count ]
      }
    end

    it "すべて叩いても既存のレコードは変わらない" do
      request_all_actions

      expect(item.reload.name).to eq "もとの品目"
      expect(item).not_to be_archived
      expect(lot.reload.initial_quantity).to eq 5
      expect(item.current_quantity).to eq 5
      expect(category.reload.name).to eq "もとのカテゴリ"
      expect(storage_location.reload.name).to eq "もとの保管場所"
      expect(store.reload.name).to eq "もとの店舗"
    end
  end

  describe "ログイン済みの一般ユーザー" do
    before { sign_in create(:user) }

    authenticated_actions.each do |name, verb, path, params|
      it "#{name} は拒否されない (品目とマスタは管理者限定ではない)" do
        request_action(verb, path, params)

        expect(response).not_to have_http_status(:forbidden)
        expect(response).not_to redirect_to new_session_path
      end
    end
  end
end
