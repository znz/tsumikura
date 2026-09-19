require "rails_helper"

# 「直近の棚卸日より前の日付です」の警告 (docs/spec/01-domain-model.md 判断 1)。
# 残数は符号付き数量の総和なので、棚卸より前の日付に記録を足すと理屈上は矛盾する。
# **保存はブロックしない** (docs/spec/03-screens.md 4 節)。
# 棚卸は保管場所ごとなので、判定は**品目単位**で行う。
RSpec.describe "棚卸日より前の記録の警告", type: :request do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:user) { create(:user) }
  let(:item) { create(:item, name: "たまご", unit: "個") }
  let(:warning) { "直近の棚卸日" }

  before do
    sign_in user
    create(:lot, item: item, initial_quantity: 10, acquired_on: Date.current - 30)
  end

  # 確定済みの棚卸の明細は作れないので、実際の順番どおり「数えてから確定する」
  def count_in_stock_take(counted_on, target: item, counted: 1, finalized: true)
    stock_take = create(:stock_take, user: user, counted_on: counted_on)
    create(:stock_take_entry, stock_take: stock_take, item: target,
      expected_quantity: target.current_quantity, counted_quantity: counted)
    stock_take.update_column(:finalized_at, Time.current) if finalized
    stock_take
  end

  describe "使用の記録" do
    it "棚卸日より前の日付で記録すると、保存したうえで警告する" do
      count_in_stock_take(Date.current - 3)

      post item_usage_records_path(item),
        params: { usage_record: { quantity: "1", used_on: (Date.current - 5).to_s } }

      expect(item.reload.current_quantity).to eq 9
      expect(flash[:notice]).to include warning
    end

    it "棚卸日と同じ日付なら警告しない" do
      count_in_stock_take(Date.current - 3)

      post item_usage_records_path(item),
        params: { usage_record: { quantity: "1", used_on: (Date.current - 3).to_s } }

      expect(flash[:notice]).not_to include warning
    end

    it "確定済みの棚卸が無ければ警告しない (下書きは数えない)" do
      count_in_stock_take(Date.current, finalized: false)

      post item_usage_records_path(item),
        params: { usage_record: { quantity: "1", used_on: (Date.current - 5).to_s } }

      expect(flash[:notice]).not_to include warning
    end

    # 冷蔵庫を数えただけで、洗剤の記録にまで警告が出ると読まれなくなる
    it "この品目を数えていない棚卸では警告しない" do
      count_in_stock_take(Date.current - 3, target: create(:item, name: "洗剤"))

      post item_usage_records_path(item),
        params: { usage_record: { quantity: "1", used_on: (Date.current - 5).to_s } }

      expect(flash[:notice]).not_to include warning
    end

    it "実数を入れずにスキップした品目でも警告しない" do
      count_in_stock_take(Date.current - 3, counted: nil)

      post item_usage_records_path(item),
        params: { usage_record: { quantity: "1", used_on: (Date.current - 5).to_s } }

      expect(flash[:notice]).not_to include warning
    end

    it "編集で日付を戻したときも警告する" do
      count_in_stock_take(Date.current - 3)
      usage = Stock::RecordUsage.call(item: item, user: user,
        attributes: { quantity: 1, used_on: Date.current })

      patch usage_record_path(usage),
        params: { usage_record: { quantity: "1", used_on: (Date.current - 5).to_s } }

      expect(flash[:notice]).to include warning
    end

    it "フォームにも直近の棚卸日を出す" do
      count_in_stock_take(Date.current - 3)

      get new_item_usage_record_path(item)

      expect(response.body).to include warning
    end

    it "数えていない品目のフォームには出さない" do
      count_in_stock_take(Date.current - 3, target: create(:item, name: "洗剤"))

      get new_item_usage_record_path(item)

      expect(response.body).not_to include warning
    end
  end

  describe "購入の記録" do
    it "棚卸日より前の購入日で記録すると、保存したうえで警告する" do
      count_in_stock_take(Date.current - 3)

      post item_lots_path(item),
        params: { lot: { acquired_on: (Date.current - 5).to_s, initial_quantity: "3" } }

      expect(item.reload.current_quantity).to eq 13
      expect(flash[:notice]).to include warning
    end

    it "今日の購入なら警告しない" do
      count_in_stock_take(Date.current - 3)

      post item_lots_path(item),
        params: { lot: { acquired_on: Date.current.to_s, initial_quantity: "3" } }

      expect(flash[:notice]).not_to include warning
    end
  end

  describe "廃棄の記録" do
    it "棚卸日より前の廃棄日で記録すると、保存したうえで警告する" do
      count_in_stock_take(Date.current - 3)

      post item_disposals_path(item), params: { disposal: {
        quantity: "1", occurred_on: (Date.current - 5).to_s, disposal_reason: "expired"
      } }

      expect(item.reload.current_quantity).to eq 9
      expect(flash[:toast]).to include warning
    end
  end
end
