require "rails_helper"

RSpec.describe "買い物リスト", type: :request do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:user) { create(:user, name: "おかあさん") }

  before { sign_in user }

  # 最低在庫数を下回っていれば urgent、ちょうどなら soon (docs/spec/02-forecast.md 6 節)
  def urgent_item(name:, **attributes)
    create(:item, name: name, minimum_quantity: 5, **attributes).tap { |item| stock_up(item, 3) }
  end

  def soon_item(name:, **attributes)
    create(:item, name: name, minimum_quantity: 3, **attributes).tap { |item| stock_up(item, 3) }
  end

  describe "GET /shopping_list" do
    it "要購入 (urgent) の品目が自動で並ぶ" do
      urgent_item(name: "ティッシュ")

      get shopping_list_path

      expect(response).to have_http_status(:ok)
      expect(rendered_list("要購入の品目")).to include "ティッシュ"
    end

    it "そろそろ購入 (soon) の品目も並ぶ" do
      soon_item(name: "しょうゆ")

      get shopping_list_path

      expect(rendered_list("要購入の品目")).to include "しょうゆ"
    end

    it "購入不要 (ok) とデータ不足 (unknown) の品目は並ばない" do
      stock_up(create(:item, name: "じゅうぶん", minimum_quantity: 1), 10)
      # 在庫はあるがペースも最低在庫数も分からない = unknown (docs/spec/02-forecast.md 1 節)
      stock_up(create(:item, name: "ぺーすふめい"), 5)

      get shopping_list_path

      expect(rendered_list("要購入の品目")).not_to include "じゅうぶん"
      expect(rendered_list("要購入の品目")).not_to include "ぺーすふめい"
    end

    # 在庫イベントが 1 件も無い auto の品目は q = 0 でペース不明なので :out_of_stock の urgent
    # になる (docs/spec/02-forecast.md 7 節)。仕様どおりの挙動で、緩和しないことを固定する
    it "在庫を 1 度も登録していない品目は、仕様どおり購入推奨として並ぶ" do
      create(:item, name: "きろくなし")

      get shopping_list_path

      expect(rendered_list("要購入の品目")).to include "きろくなし"
    end

    it "アーカイブ済みの品目は並ばない" do
      urgent_item(name: "アーカイブずみ").archive!

      get shopping_list_path

      expect(rendered_list("要購入の品目")).not_to include "アーカイブずみ"
    end

    it "手動追加した自由入力の行が並ぶ" do
      create(:shopping_list_item, :free_text, free_text: "はがき", added_by: user)

      get shopping_list_path

      expect(rendered_list("手動で追加した品目")).to include "はがき"
    end

    it "自由入力はエスケープされる (HTML として解釈しない)" do
      create(:shopping_list_item, :free_text, free_text: "<script>alert(1)</script>", added_by: user)

      get shopping_list_path

      expect(response.body).not_to include "<script>alert(1)</script>"
      expect(rendered_list("手動で追加した品目")).to include "<script>alert(1)</script>"
    end

    it "スヌーズ中の品目は要購入に出さず、畳んで件数を出す" do
      item = urgent_item(name: "すぬーずちゅう")
      create(:shopping_list_item, :snoozed, item: item, added_by: user)

      get shopping_list_path

      expect(rendered_list("要購入の品目")).not_to include "すぬーずちゅう"
      expect(rendered_list("スヌーズ中の品目")).to include "すぬーずちゅう"
      expect(response.body).to include "スヌーズ中 (1 件)"
    end

    it "スヌーズが切れた品目は自動で要購入に戻る" do
      item = urgent_item(name: "もどってきた")
      create(:shopping_list_item, item: item, added_by: user, snoozed_until: Date.current - 1)

      get shopping_list_path

      expect(rendered_list("要購入の品目")).to include "もどってきた"
    end

    # id が変わると、リダイレクト先のアンカーも Turbo の morph の対応付けも外れて
    # スクロール位置が飛ぶ (店頭で長いリストをチェックするたびに先頭に戻る)
    it "品目の行の id は永続行の有無で変わらない" do
      item = urgent_item(name: "ティッシュ")
      dom_id = ShoppingLists::Row.dom_id(item_id: item.id)

      get shopping_list_path
      expect(response.parsed_body.at("##{dom_id}")).to be_present

      create(:shopping_list_item, :checked, item: item, added_by: user)
      get shopping_list_path

      expect(response.parsed_body.at("##{dom_id}")).to be_present
    end

    it "Turbo の再表示では morph してスクロール位置を保つ" do
      get shopping_list_path

      expect(response.parsed_body.at("meta[name='turbo-refresh-method']")[:content]).to eq "morph"
      expect(response.parsed_body.at("meta[name='turbo-refresh-scroll']")[:content]).to eq "preserve"
    end

    it "一覧を開いても行は作られない (GET に副作用を出さない)" do
      urgent_item(name: "ティッシュ")

      expect { get shopping_list_path }.not_to change(ShoppingListItem, :count)
    end

    it "チェック済みがあれば「購入として記録」への導線が出る" do
      item = urgent_item(name: "ティッシュ")
      create(:shopping_list_item, :checked, item: item, added_by: user)

      get shopping_list_path

      expect(response.parsed_body.at("a[href='#{new_purchase_path}']")).to be_present
    end

    it "チェック済みが無ければ「購入として記録」は出さない" do
      urgent_item(name: "ティッシュ")

      get shopping_list_path

      expect(response.parsed_body.at("a[href='#{new_purchase_path}']")).to be_nil
    end

    it "在庫は判定に使った数 (期限切れを除く) を出す" do
      item = create(:item, :tracks_expiry, name: "ぎゅうにゅう", minimum_quantity: 5)
      stock_up(item, 3, expires_on: Date.current - 1)
      stock_up(item, 2)

      get shopping_list_path

      expect(item.reload.current_quantity).to eq 5
      expect(rendered_list("要購入の品目")).to include "在庫 2"
    end

    it "品目が増えてもクエリ数は増えない" do
      2.times { |i| urgent_item(name: "しな#{i}") }
      get shopping_list_path
      baseline = count_queries { get shopping_list_path }

      3.times { |i| urgent_item(name: "あと#{i}") }

      expect(count_queries { get shopping_list_path }).to eq baseline
    end
  end
end
