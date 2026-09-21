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

  [ "使用の入力フォーム", :get, -> { new_item_usage_record_path(item) }, -> { {} } ],
  [ "使用の記録", :post, -> { item_usage_records_path(item) },
    -> { { usage_record: { quantity: "1", used_on: Date.current.to_s } } } ],
  [ "ワンタップ使用", :post, -> { item_quick_use_path(item) }, -> { {} } ],
  [ "使用の記録の編集フォーム", :get, -> { edit_usage_record_path(usage_record) }, -> { {} } ],
  [ "使用の記録の更新", :patch, -> { usage_record_path(usage_record) },
    -> { { usage_record: { quantity: "4", used_on: Date.current.to_s } } } ],
  [ "使用の記録の削除", :delete, -> { usage_record_path(usage_record) }, -> { {} } ],

  [ "用途一覧", :get, -> { item_purposes_path(item) }, -> { {} } ],
  [ "用途の追加フォーム", :get, -> { new_item_purpose_path(item) }, -> { {} } ],
  [ "用途の追加", :post, -> { item_purposes_path(item) }, -> { { item_purpose: { name: "しんき" } } } ],
  [ "用途の編集フォーム", :get, -> { edit_item_purpose_path(item, purpose) }, -> { {} } ],
  [ "用途の更新", :patch, -> { item_purpose_path(item, purpose) },
    -> { { item_purpose: { name: "のっとり" } } } ],
  [ "用途の並べ替え", :patch, -> { item_purpose_position_path(item, purpose) },
    -> { { direction: "up" } } ],
  [ "用途のアーカイブ", :post, -> { item_purpose_archive_path(item, purpose) }, -> { {} } ],
  [ "用途のアーカイブ解除", :delete, -> { item_purpose_archive_path(item, purpose) }, -> { {} } ],
  [ "用途の削除", :delete, -> { item_purpose_path(item, purpose) }, -> { {} } ],

  [ "廃棄の入力フォーム", :get, -> { new_item_disposal_path(item) }, -> { {} } ],
  [ "廃棄の記録", :post, -> { item_disposals_path(item) },
    -> { { disposal: { quantity: "1", occurred_on: Date.current.to_s, disposal_reason: "expired" } } } ],
  [ "廃棄の取り消し", :delete, -> { disposal_path(disposal) }, -> { {} } ],

  [ "棚卸一覧", :get, -> { stock_takes_path }, -> { {} } ],
  [ "棚卸の追加フォーム", :get, -> { new_stock_take_path }, -> { {} } ],
  [ "棚卸の作成", :post, -> { stock_takes_path },
    -> { { stock_take: { counted_on: Date.current.to_s } } } ],
  [ "棚卸の詳細", :get, -> { stock_take_path(stock_take) }, -> { {} } ],
  [ "棚卸の入力フォーム", :get, -> { edit_stock_take_path(stock_take) }, -> { {} } ],
  [ "棚卸の更新", :patch, -> { stock_take_path(stock_take) },
    -> { { counts: { item.id.to_s => { total: "99" } } } } ],
  [ "棚卸の確定", :post, -> { stock_take_finalization_path(stock_take) }, -> { {} } ],
  [ "棚卸の削除", :delete, -> { stock_take_path(stock_take) }, -> { {} } ],

  [ "購入の入力フォーム", :get, -> { new_item_lot_path(item) }, -> { {} } ],
  [ "購入の記録", :post, -> { item_lots_path(item) },
    -> { { lot: { acquired_on: Date.current.to_s, initial_quantity: "1" } } } ],
  [ "購入の記録の編集フォーム", :get, -> { edit_lot_path(lot) }, -> { {} } ],
  [ "購入の記録の更新", :patch, -> { lot_path(lot) },
    -> { { lot: { acquired_on: Date.current.to_s, initial_quantity: "99" } } } ],
  [ "購入の記録の削除", :delete, -> { lot_path(lot) }, -> { {} } ],

  [ "買い物リスト", :get, -> { shopping_list_path }, -> { {} } ],
  [ "買い物リストへの追加", :post, -> { shopping_list_items_path },
    -> { { shopping_list_item: { free_text: "しんき" } } } ],
  [ "買い物リストの行の更新", :patch, -> { shopping_list_item_path(shopping_list_item) },
    -> { { shopping_list_item: { quantity: "9" } } } ],
  [ "買い物リストの行の削除", :delete, -> { shopping_list_item_path(shopping_list_item) },
    -> { {} } ],

  [ "まとめ購入のフォーム", :get, -> { new_purchase_path }, -> { {} } ],
  [ "まとめ購入の記録", :post, -> { purchases_path },
    -> { { purchase: { acquired_on: Date.current.to_s,
                       lines: { shopping_list_item.id.to_s => { initial_quantity: "1" } } } } } ],

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
  [ "店舗の削除", :delete, -> { store_path(store) }, -> { {} } ],

  [ "メニュー", :get, -> { menu_path }, -> { {} } ],
  [ "記録メニュー", :get, -> { record_menu_path }, -> { {} } ],

  [ "通知の購読", :post, -> { web_push_subscriptions_path },
    -> { { web_push_subscription: { endpoint: push_endpoint("authorization-new"),
                                    p256dh: push_p256dh, auth: push_auth } } } ],
  [ "通知の購読の削除", :delete, -> { web_push_subscription_path(web_push_subscription) }, -> { {} } ],
  [ "通知のテスト送信", :post, -> { notification_test_path }, -> { {} } ],
  [ "通知の種別の更新", :patch, -> { account_notification_setting_path },
    -> { { user: { notify_purchases: "0", notify_expiries: "0" } } } ],

  # パスキー (docs/spec/05-auth.md 5 節)。**未ログインで通すのは
  # sessions/passkeys の options / create だけ**なので、この 3 つはここで守る
  [ "パスキーの登録オプション", :post, -> { options_passkeys_path },
    -> { { current_password: "family-password" } } ],
  [ "パスキーの登録", :post, -> { passkeys_path }, -> { { credential: "{}" } } ],
  [ "パスキーの削除", :delete, -> { passkey_path(passkey) }, -> { {} } ]
]

RSpec.describe "品目とマスタの認可", type: :request do
  let(:item) { create(:item, name: "もとの品目", tracks_purposes: true) }
  let(:lot) { create(:lot, item: item, initial_quantity: 5) }
  let(:purpose) { create(:item_purpose, item: item, name: "もとの用途") }
  let(:usage_record) { create(:usage_record, item: item, quantity: 2, used_on: Date.current) }
  let(:disposal) do
    lot   # 在庫が無いと廃棄できないので、先に購入の記録を作っておく
    Stock::RecordDisposal.call(item: item, user: create(:user), attributes: {
      quantity: 1, occurred_on: Date.current, disposal_reason: "expired"
    }).movements.sole
  end
  let(:stock_take) { create(:stock_take, note: "もとの棚卸") }
  # まとめ購入の対象になるチェック済みの行
  let(:shopping_list_item) { create(:shopping_list_item, :checked, item: item, added_by: create(:user)) }
  # 通知の購読は**他人のもの**を置く (消せないことを確かめるため)
  let(:web_push_subscription) { create(:web_push_subscription, endpoint: push_endpoint("authorization-other")) }
  # パスキーも**他人のもの**を置く (消せないことを確かめるため)
  let(:passkey) { create(:passkey) }
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
  it "表は品目・記録・マスタの全ルートを網羅している" do
    target_controllers = %w[
      items items/archives items/quick_uses
      usage_records lots disposals
      stock_takes stock_takes/finalizations
      shopping_lists shopping_list_items purchases
      web_push_subscriptions notification_tests account/notification_settings
      passkeys
      item_purposes item_purposes/positions item_purposes/archives
      categories categories/positions
      storage_locations storage_locations/positions
      stores
      menus record_menus
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
      purpose
      usage_record
      disposal
      stock_take
      shopping_list_item
      web_push_subscription
      passkey
      category
      storage_location
      store

      expect { request_all_actions }.not_to change {
        [ Item.count, Lot.count, StockMovement.count, UsageRecord.count, ItemPurpose.count,
          StockTake.count, StockTakeEntry.count, ShoppingListItem.count, WebPushSubscription.count,
          Passkey.count, Category.count, StorageLocation.count, Store.count ]
      }
    end

    it "すべて叩いても既存のレコードは変わらない" do
      # let は遅延評価なので、購入より先に使用が記録されないよう順番に作っておく
      item
      lot
      purpose
      usage_record
      disposal
      stock_take
      shopping_list_item
      web_push_subscription
      passkey

      request_all_actions

      expect(item.reload.name).to eq "もとの品目"
      expect(item).not_to be_archived
      expect(lot.reload.initial_quantity).to eq 5
      expect(purpose.reload.name).to eq "もとの用途"
      expect(purpose).not_to be_archived
      expect(usage_record.reload.quantity).to eq 2
      expect(stock_take.reload.finalized_at).to be_nil
      expect(shopping_list_item.reload).to be_checked
      expect(shopping_list_item.quantity).to be_nil
      expect(item.current_quantity).to eq 2
      expect(WebPushSubscription.exists?(web_push_subscription.id)).to be true
      expect(Passkey.exists?(passkey.id)).to be true
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
