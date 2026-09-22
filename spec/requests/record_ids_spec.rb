require "rails_helper"

# URL に出る id の約束 (docs/spec/03-screens.md / docs/spec/01-domain-model.md 2 節)。
#
# * 主キーは UUIDv7。連番ではないので、URL から件数も前後のレコードも推測できない
# * パスと GET のクエリに出る id は **Base58 の 22 文字**
# * 生の UUID は URL では受け付けない (表現を 1 つに保つ)
# * 読めない id は 500 ではなく 404 / 無視
# * POST / PATCH の本文に入る id (select の値・hidden・counts[<id>]) は UUID のまま
#
# コントローラを足したら、下の表にも足すこと。
RSpec.describe "URL の id", type: :request do
  let(:user) { create(:user, role: :admin) }
  let(:item) { create(:item, name: "トイレットペーパー", tracks_purposes: true) }

  before { sign_in user }

  describe "to_param" do
    it "Base58 の 22 文字になる (URL に連番は出ない)" do
      expect(item.to_param.length).to eq 22
      expect(item.to_param).to match(/\A[#{Base58Uuid::ALPHABET}]{22}\z/)
      expect(item_path(item)).to eq "/items/#{item.to_param}"
    end

    it "Base58 から元の UUID に戻せる" do
      expect(Base58Uuid.decode(item.to_param)).to eq item.id
    end

    it "保存前は nil (URL を作れない)" do
      expect(Item.new.to_param).to be_nil
    end

    it "URL に生の UUID は出てこない" do
      expect(item_path(item)).not_to include item.id
      expect(item_path(item)).not_to include item.id.delete("-")
    end
  end

  describe ".find_by_param!" do
    it "Base58 で引ける" do
      expect(Item.find_by_param!(item.to_param)).to eq item
    end

    it "relation / 関連からも引ける" do
      purpose = create(:item_purpose, item: item, name: "ふだん")

      expect(item.item_purposes.find_by_param!(purpose.to_param)).to eq purpose
    end

    it "relation の絞り込みは効いたまま" do
      other = create(:item_purpose, item: create(:item), name: "よそ")

      expect { item.item_purposes.find_by_param!(other.to_param) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end

    it "生の UUID は受け付けない" do
      expect { Item.find_by_param!(item.id) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "読めない Base58 は RecordNotFound (例外の種類を変えない)" do
      [ "0" * 22, "1" * 21, "1" * 23, "", nil, 0, [ "1" * 22 ], { id: "1" * 22 },
        :"#{'1' * 22}", 1.0 ].each do |param|
        expect { Item.find_by_param!(param) }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    it "大文字だけが違う Base58 は別物 (辞書順のために大小を区別している)" do
      swapped = item.to_param.tr("a-zA-Z", "A-Za-z")
      next if swapped == item.to_param

      expect { Item.find_by_param!(swapped) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe ".find_by_param (無ければ nil)" do
    it "Base58 で引ける" do
      expect(Item.find_by_param(item.to_param)).to eq item
    end

    # **生の UUID で引けてしまうと、「案内して戻す / 成功扱い」の画面から
    # UUID 指定で他人のレコードを消せる退行に気づけない**
    it "生の UUID は nil" do
      expect(Item.find_by_param(item.id)).to be_nil
    end

    it "読めない値も nil (例外にしない)" do
      [ "0" * 22, "1" * 21, "", nil, 0, [ "1" * 22 ], { id: "1" * 22 } ].each do |param|
        expect(Item.find_by_param(param)).to be_nil
      end
    end
  end

  # 表: [名前, リクエスト, レコードを作る手順]。
  # 「生の UUID を URL に入れると 404」「読めない id でも 500 にしない」を総当たりで固定する
  resources = [
    [ "品目", ->(id) { get item_path(id) }, -> { create(:item) } ],
    [ "品目の編集", ->(id) { get edit_item_path(id) }, -> { create(:item) } ],
    [ "記録の全履歴 (品目 id)", ->(id) { get item_records_path(item_id: id) }, -> { create(:item) } ],
    [ "用途一覧 (品目 id)", ->(id) { get item_purposes_path(item_id: id) }, -> { create(:item) } ],
    [ "使用の入力 (品目 id)", ->(id) { get new_item_usage_record_path(item_id: id) }, -> { create(:item) } ],
    [ "購入の入力 (品目 id)", ->(id) { get new_item_lot_path(item_id: id) }, -> { create(:item) } ],
    [ "廃棄の入力 (品目 id)", ->(id) { get new_item_disposal_path(item_id: id) }, -> { create(:item) } ],
    [ "使用の記録の編集", ->(id) { get edit_usage_record_path(id) },
      -> { create(:lot, initial_quantity: 5).then { |lot| create(:usage_record, item: lot.item, quantity: 1) } } ],
    [ "購入の記録の編集", ->(id) { get edit_lot_path(id) }, -> { create(:lot, initial_quantity: 5) } ],
    [ "棚卸の詳細", ->(id) { get stock_take_path(id) }, -> { create(:stock_take) } ],
    [ "棚卸の入力", ->(id) { get edit_stock_take_path(id) }, -> { create(:stock_take) } ],
    [ "カテゴリの編集", ->(id) { get edit_category_path(id) }, -> { create(:category) } ],
    [ "保管場所の編集", ->(id) { get edit_storage_location_path(id) }, -> { create(:storage_location) } ],
    [ "店舗の編集", ->(id) { get edit_store_path(id) }, -> { create(:store) } ],
    [ "ユーザーの編集 (管理者)", ->(id) { get edit_admin_user_path(id) }, -> { create(:user) } ]
  ]

  resources.each do |name, request, build_record|
    describe name do
      it "Base58 の id で開ける" do
        record = instance_exec(&build_record)

        instance_exec(record.to_param, &request)

        expect(response).to have_http_status(:ok)
      end

      it "生の UUID を URL に入れると 404" do
        record = instance_exec(&build_record)

        instance_exec(record.id, &request)

        expect(response).to have_http_status(:not_found)
      end

      it "読めない Base58 でも 404 (500 にしない)" do
        instance_exec(&build_record)

        instance_exec(malformed_param, &request)

        expect(response).to have_http_status(:not_found)
      end

      it "存在しない Base58 は 404" do
        instance_exec(&build_record)

        instance_exec(nonexistent_param, &request)

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # GET 以外のアクション。成功時の応答はそれぞれ違うので、**引けない id で 404 になること**
  # だけを総当たりで固定する (find_by_param! を使う側の置き換え漏れを検出する)。
  # ルートを足したらこの表にも足すこと
  guarded_actions = [
    [ "品目のアーカイブ", ->(id) { post item_archive_path(item_id: id) }, -> { create(:item) } ],
    [ "品目の復元", ->(id) { delete item_archive_path(item_id: id) }, -> { create(:item) } ],
    [ "ワンタップ使用", ->(id) { post item_quick_use_path(item_id: id) }, -> { create(:item) } ],
    [ "用途の編集", ->(id) { get edit_item_purpose_path(item, id) },
      -> { create(:item_purpose, item: item) } ],
    [ "用途の更新", ->(id) { patch item_purpose_path(item, id), params: { item_purpose: { name: "の" } } },
      -> { create(:item_purpose, item: item) } ],
    [ "用途の削除", ->(id) { delete item_purpose_path(item, id) },
      -> { create(:item_purpose, item: item) } ],
    [ "用途の並べ替え", ->(id) { patch item_purpose_position_path(item, id), params: { direction: "up" } },
      -> { create(:item_purpose, item: item) } ],
    [ "用途のアーカイブ", ->(id) { post item_purpose_archive_path(item, id) },
      -> { create(:item_purpose, item: item) } ],
    [ "用途のアーカイブ解除", ->(id) { delete item_purpose_archive_path(item, id) },
      -> { create(:item_purpose, item: item) } ],
    [ "使用の記録の更新",
      ->(id) { patch usage_record_path(id), params: { usage_record: { quantity: "1", used_on: Date.current.to_s } } },
      -> { create(:lot, initial_quantity: 5).then { |lot| create(:usage_record, item: lot.item, quantity: 1) } } ],
    [ "購入の記録の更新",
      ->(id) { patch lot_path(id), params: { lot: { acquired_on: Date.current.to_s, initial_quantity: "9" } } },
      -> { create(:lot, initial_quantity: 5) } ],
    [ "購入の記録の削除", ->(id) { delete lot_path(id) }, -> { create(:lot, initial_quantity: 5) } ],
    [ "棚卸の更新", ->(id) { patch stock_take_path(id), params: { counts: {} } }, -> { create(:stock_take) } ],
    [ "棚卸の削除", ->(id) { delete stock_take_path(id) }, -> { create(:stock_take) } ],
    [ "棚卸の確定", ->(id) { post stock_take_finalization_path(stock_take_id: id) },
      -> { create(:stock_take) } ],
    [ "カテゴリの更新", ->(id) { patch category_path(id), params: { category: { name: "の" } } },
      -> { create(:category) } ],
    [ "カテゴリの削除", ->(id) { delete category_path(id) }, -> { create(:category) } ],
    [ "カテゴリの並べ替え", ->(id) { patch category_position_path(category_id: id), params: { direction: "up" } },
      -> { create(:category) } ],
    [ "保管場所の更新", ->(id) { patch storage_location_path(id), params: { storage_location: { name: "の" } } },
      -> { create(:storage_location) } ],
    [ "保管場所の削除", ->(id) { delete storage_location_path(id) }, -> { create(:storage_location) } ],
    [ "保管場所の並べ替え",
      ->(id) { patch storage_location_position_path(storage_location_id: id), params: { direction: "up" } },
      -> { create(:storage_location) } ],
    [ "店舗の更新", ->(id) { patch store_path(id), params: { store: { name: "の" } } }, -> { create(:store) } ],
    [ "店舗の削除", ->(id) { delete store_path(id) }, -> { create(:store) } ],
    [ "ユーザーの更新 (管理者)",
      ->(id) { patch admin_user_path(id), params: { user: { name: "の" } } }, -> { create(:user) } ],
    [ "パスワード再設定のフォーム (管理者)", ->(id) { get new_admin_user_password_reset_path(user_id: id) },
      -> { create(:user) } ],
    [ "パスワード再設定 (管理者)", ->(id) { post admin_user_password_reset_path(user_id: id) },
      -> { create(:user) } ],
    [ "ユーザーの無効化 (管理者)", ->(id) { post admin_user_deactivation_path(user_id: id) },
      -> { create(:user) } ],
    [ "ユーザーの再有効化 (管理者)", ->(id) { delete admin_user_deactivation_path(user_id: id) },
      -> { create(:user) } ],
    [ "デバイスのログアウト", ->(id) { delete account_session_path(id) }, -> { user.sessions.sole } ]
  ]

  guarded_actions.each do |name, request, build_record|
    describe name do
      it "引けない id はどれも 404 (500 にしない)" do
        record = instance_exec(&build_record)

        [ record.id, malformed_param, nonexistent_param ].each do |param|
          instance_exec(param, &request)

          expect(response).to have_http_status(:not_found),
            "#{name} に #{param.inspect} を渡したら #{response.status} だった"
        end
      end
    end
  end

  # **404 にせず「案内して戻す / 成功として扱う」アクション** (find_by_param を使う側)。
  # 404 を見せない分、生の UUID で引けてしまう退行に気づけないので、
  # 「レコードが消えない / 変わらない」ことで固定する
  describe "消えていても 404 にしないアクション" do
    it "使用の記録の削除に生の UUID を渡しても消えない" do
      lot = create(:lot, initial_quantity: 5)
      record = create(:usage_record, item: lot.item, quantity: 1)

      [ record.id, malformed_param, nonexistent_param ].each do |param|
        expect { delete usage_record_path(param) }.not_to change(UsageRecord, :count)
        expect(response).to have_http_status(:see_other)
      end
      expect(UsageRecord.exists?(record.id)).to be true
    end

    it "廃棄の取り消しに生の UUID を渡しても消えない" do
      item = create(:item)
      create(:lot, item: item, initial_quantity: 5)
      movement = Stock::RecordDisposal.call(item: item, user: user, attributes: {
        quantity: 1, occurred_on: Date.current, disposal_reason: "expired"
      }).movements.sole

      [ movement.id, malformed_param, nonexistent_param ].each do |param|
        expect { delete disposal_path(param) }.not_to change(StockMovement, :count)
      end
      expect(StockMovement.exists?(movement.id)).to be true
    end

    it "買い物リストの行の更新・削除に生の UUID を渡しても変わらない" do
      entry = create(:shopping_list_item, item: create(:item), added_by: user)

      [ entry.id, malformed_param, nonexistent_param ].each do |param|
        patch shopping_list_item_path(param), params: { shopping_list_item: { quantity: "99" } }
        expect(response).to redirect_to shopping_list_path

        expect { delete shopping_list_item_path(param) }.not_to change(ShoppingListItem, :count)
      end
      expect(entry.reload.quantity).to be_nil
    end

    # ここは「成功として扱う」経路なので、生の UUID で消せると退行に気づけない
    it "パスキーの削除に生の UUID を渡しても消えない" do
      passkey = create(:passkey, user: user)

      [ passkey.id, malformed_param, nonexistent_param ].each do |param|
        expect { delete passkey_path(param) }.not_to change(Passkey, :count)
      end
      expect(Passkey.exists?(passkey.id)).to be true
    end

    it "通知の購読の削除に生の UUID を渡しても消えない" do
      subscription = create(:web_push_subscription, user: user)

      [ subscription.id, malformed_param, nonexistent_param ].each do |param|
        expect { delete web_push_subscription_path(param) }.not_to change(WebPushSubscription, :count)
      end
      expect(WebPushSubscription.exists?(subscription.id)).to be true
    end
  end

  # GET のクエリに出る id は Base58 (アドレスバーに見えるため)
  describe "一覧の絞り込み (GET のクエリ)" do
    let(:category) { create(:category, name: "日用品") }
    let(:storage_location) { create(:storage_location, name: "洗面所") }

    before do
      create(:item, name: "ティッシュ", category: category, storage_location: storage_location)
      create(:item, name: "しょうゆ")
    end

    it "カテゴリは Base58 で絞り込める" do
      get items_path, params: { category_id: category.to_param }

      expect(rendered_list("品目一覧")).to include "ティッシュ"
      expect(rendered_list("品目一覧")).not_to include "しょうゆ"
    end

    it "保管場所は Base58 で絞り込める" do
      get items_path, params: { storage_location_id: storage_location.to_param }

      expect(rendered_list("品目一覧")).to include "ティッシュ"
      expect(rendered_list("品目一覧")).not_to include "しょうゆ"
    end

    it "生の UUID は絞り込みに使えない (指定なしに倒す)" do
      get items_path, params: { category_id: category.id }

      expect(response).to have_http_status(:ok)
      expect(rendered_list("品目一覧")).to include "しょうゆ"
    end

    it "読めない値は指定なしに倒す (0 件にも 500 にもしない)" do
      [ malformed_param, "1", "", "abc" ].each do |value|
        get items_path, params: { category_id: value }

        expect(response).to have_http_status(:ok)
        expect(rendered_list("品目一覧")).to include "しょうゆ"
      end
    end

    it "配列やハッシュでも 500 にしない" do
      get items_path, params: { category_id: [ "1" ], storage_location_id: { a: "1" } }

      expect(response).to have_http_status(:ok)
    end

    it "セレクトの選択肢は Base58 で、選んだ値が残る" do
      get items_path, params: { category_id: category.to_param }

      expect(response.body).to include %(value="#{category.to_param}")
      expect(response.body).not_to include %(value="#{category.id}")
      expect(response.parsed_body.at("option[selected][value='#{category.to_param}']")).to be_present
    end
  end

  # 廃棄フォームの lot_id は GET のクエリ (ロット行の「廃棄」リンク) なので Base58。
  # セレクトの option の値は POST の本文にしか出ないので UUID のまま
  describe "廃棄の入力の lot_id (GET のクエリ)" do
    let(:item) { create(:item, tracks_expiry: true) }
    let!(:expired) { create(:lot, item: item, initial_quantity: 2, expires_on: Date.current - 1) }

    it "Base58 ならそのロットが選ばれた状態で開く" do
      get new_item_disposal_path(item, lot_id: expired.to_param)

      expect(response.parsed_body.at("option[selected][value='#{expired.id}']")).to be_present
    end

    it "生の UUID は未選択に倒れる (500 にも 404 にもしない)" do
      get new_item_disposal_path(item, lot_id: expired.id)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.at("option[selected]")).to be_nil
    end

    it "読めない値も未選択に倒れる" do
      [ malformed_param, "1", "", "abc", nonexistent_param ].each do |value|
        get new_item_disposal_path(item, lot_id: value)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.at("option[selected]")).to be_nil
      end
    end
  end

  # DB を作り直すと、UUID 化より前の**整数の session_id が入った Cookie** を持ったままの
  # ブラウザが戻ってくる。uuid 列は整数を nil にキャストするので、セッションが復元できずに
  # ログイン画面へ送られる (500 にはならない) ことを固定する
  describe "UUID 化より前の Cookie" do
    # アプリと同じ仕組みで署名した Cookie を作る (request spec の cookies は signed を持たない)
    def signed_cookie_value(name, value)
      request = ActionDispatch::Request.new(
        Rails.application.env_config.merge(Rack::MockRequest.env_for("/"))
      )
      jar = ActionDispatch::Cookies::CookieJar.build(request, {})
      jar.signed[name] = value
      jar[name]
    end

    it "整数の session_id を持っていても 500 にならず、ログイン画面へ送られる" do
      [ 1, 12345, 2**62 ].each do |old_id|
        cookies[:session_id] = signed_cookie_value(:session_id, old_id)

        get root_path

        expect(response).to redirect_to new_session_path
      end
    end

    it "整数の session_id ではセッションを引けない (nil に倒れる)" do
      expect(Session.active.find_by(id: 12345)).to be_nil
    end
  end

  # POST / PATCH の本文に入る id は URL に出ないので UUID のまま
  describe "POST の本文の id" do
    it "買い物リストへの追加は UUID の item_id を受ける" do
      urgent = create(:item, name: "せっけん")

      expect {
        post shopping_list_items_path,
          params: { shopping_list_item: { item_id: urgent.id, manual: "true" } }
      }.to change(ShoppingListItem, :count).by(1)

      expect(ShoppingListItem.sole.item).to eq urgent
    end

    it "買い物リストへの追加に Base58 を送っても行は作らない (案内して戻す)" do
      urgent = create(:item, name: "せっけん")

      expect {
        post shopping_list_items_path,
          params: { shopping_list_item: { item_id: urgent.to_param, manual: "true" } }
      }.not_to change(ShoppingListItem, :count)

      expect(response).to redirect_to shopping_list_path
    end
  end
end
