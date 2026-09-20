require "rails_helper"

# 導出 (Forecast::BatchForecaster) と永続行の読み込み。
# マージの規則そのものは spec/models/shopping_lists/merger_spec.rb (DB 不要) で見る。
RSpec.describe ShoppingLists::Builder do
  let(:today) { Date.current }

  before { freeze_time }

  # 最低在庫数を下回っていれば urgent (docs/spec/02-forecast.md 6 節)
  def urgent_item(**attributes)
    create(:item, minimum_quantity: 5, **attributes).tap { |item| stock_up(item, 3) }
  end

  it "要購入の品目は Forecast::BatchForecaster と同じ判定で並ぶ" do
    item = urgent_item(name: "といれっとぺーぱー")

    list = described_class.call(today: today)

    expect(list.rows.map(&:name)).to eq [ "といれっとぺーぱー" ]
    expect(list.rows.sole.status).to eq Forecast::BatchForecaster.call([ item ], today: today)[item.id].status
  end

  # Row は AR を読まない PORO なので上限を自前で持っている。ずれると推奨数量だけが通る
  it "推奨数量の上限は品目の数量の上限と同じ" do
    expect(ShoppingLists::Row::MAX_QUANTITY).to eq Item::MAX_QUANTITY
  end

  it "購入不要の品目は並ばない" do
    stock_up(create(:item, name: "じゅうぶんある", minimum_quantity: 1), 10)

    expect(described_class.call(today: today).rows).to be_empty
  end

  it "アーカイブ済みの品目は、永続行があっても並ばない" do
    item = urgent_item
    create(:shopping_list_item, :checked, :manual, item: item)
    item.archive!

    list = described_class.call(today: today)

    expect(list.rows).to be_empty
    expect(list.checked_rows).to be_empty
  end

  it "自由入力の行が並ぶ" do
    create(:shopping_list_item, :free_text, free_text: "はがき")

    expect(described_class.call(today: today).rows.map(&:name)).to eq [ "はがき" ]
  end

  it "在庫は判定に使った q (期限切れロットを除く) を出す" do
    item = create(:item, :tracks_expiry, minimum_quantity: 5)
    stock_up(item, 3, expires_on: today - 1)   # 期限切れ
    stock_up(item, 2)

    row = described_class.call(today: today).rows.sole

    expect(item.reload.current_quantity).to eq 5   # キャッシュは期限切れも含む
    expect(row.stock_quantity).to eq 2             # 判定に使った在庫は期限切れを除く
  end

  it "一覧を組み立てても行は作られない (GET に副作用を出さない)" do
    urgent_item

    expect { described_class.call(today: today) }.not_to change(ShoppingListItem, :count)
  end

  it "品目が増えてもクエリ数は増えない" do
    2.times { urgent_item }
    baseline = count_queries { described_class.call(today: today) }

    3.times { urgent_item }

    expect(count_queries { described_class.call(today: today) }).to eq baseline
  end
end
