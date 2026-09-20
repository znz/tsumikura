require "rails_helper"

RSpec.describe Stock::RecordBulkPurchase, type: :model do
  before { freeze_time }

  let(:user) { create(:user) }

  def checked_entry(item)
    create(:shopping_list_item, :checked, item: item, added_by: user)
  end

  def purchase_for(entries, quantities: nil, acquired_on: Date.current, store_id: nil,
    free_text_ids: [])
    lines = entries.each_with_index.map { |entry, index|
      Purchase::Line.new(record: entry, item: entry.item,
        attributes: { initial_quantity: quantities ? quantities[index] : 2 })
    }

    Purchase.new(acquired_on: acquired_on, store_id: store_id, user: user, lines: lines,
      free_text_ids: free_text_ids)
  end

  it "チェック済みの品目をまとめて記録する" do
    entries = [ checked_entry(create(:item)), checked_entry(create(:item)) ]

    result = described_class.call(purchase: purchase_for(entries, quantities: [ 3, 5 ]), user: user)

    expect(result).to be_ok
    expect(result.lot_count).to eq 2
    expect(entries.map { |entry| entry.item.reload.current_quantity }).to eq [ 3, 5 ]
    expect(ShoppingListItem.count).to eq 0
  end

  it "入庫は必ず movement とキャッシュの再計算を伴う" do
    entry = checked_entry(create(:item))

    described_class.call(purchase: purchase_for([ entry ], quantities: [ 4 ]), user: user)

    lot = Lot.sole
    expect(lot.remaining_quantity).to eq 4
    expect(lot.stock_movements.sole).to be_kind_purchase
  end

  it "1 件でも保存できなければ 1 件も記録しない" do
    entries = [ checked_entry(create(:item)), checked_entry(create(:item)) ]
    purchase = purchase_for(entries, quantities: [ 3, 0 ])

    result = described_class.call(purchase: purchase, user: user)

    expect(result.status).to eq :invalid
    expect(Lot.count).to eq 0
    expect(StockMovement.count).to eq 0
    expect(entries.first.item.reload.current_quantity).to eq 0
    # 行は消さない (やり直せるように)
    expect(ShoppingListItem.count).to eq 2
  end

  it "保存できなかった行に、エラーの付いた Lot を戻す (入力を描き直せるように)" do
    purchase = purchase_for([ checked_entry(create(:item)) ], quantities: [ 0 ])

    described_class.call(purchase: purchase, user: user)

    expect(purchase.lines.sole.errors.map(&:attribute)).to include :initial_quantity
  end

  # 複数の品目をロックするときは id の昇順 (デッドロック防止)
  it "品目は id の昇順で記録する" do
    first = create(:item)
    second = create(:item)
    entries = [ checked_entry(second), checked_entry(first) ]   # わざと降順で渡す

    described_class.call(purchase: purchase_for(entries), user: user)

    expect(Lot.order(:id).pluck(:item_id)).to eq [ first.id, second.id ]
  end

  # 「全部消えた」だけを見ていると、件数の比較を empty? に変えても気づけない
  it "行の一部だけが消えていても :stale で何も記録しない" do
    entries = [ checked_entry(create(:item)), checked_entry(create(:item)) ]
    purchase = purchase_for(entries)
    entries.first.destroy!

    result = described_class.call(purchase: purchase, user: user)

    expect(result).to be_stale
    expect(Lot.count).to eq 0
    expect(entries.second.reload).to be_checked
  end

  it "行がすでに消えていたら :stale で何も記録しない" do
    entry = checked_entry(create(:item))
    purchase = purchase_for([ entry ])
    entry.destroy!

    result = described_class.call(purchase: purchase, user: user)

    expect(result).to be_stale
    expect(Lot.count).to eq 0
  end

  it "チェックが外れていたら :stale で何も記録しない" do
    entry = checked_entry(create(:item))
    purchase = purchase_for([ entry ])
    entry.update!(checked_at: nil)

    expect(described_class.call(purchase: purchase, user: user)).to be_stale
    expect(Lot.count).to eq 0
  end

  it "フォームに出ていた自由入力のチェック済み行も消す (在庫には記録しない)" do
    entry = checked_entry(create(:item))
    free_text = create(:shopping_list_item, :free_text, :checked, added_by: user)

    result = described_class.call(
      purchase: purchase_for([ entry ], free_text_ids: [ free_text.id ]), user: user
    )

    expect(result.free_text_count).to eq 1
    expect(ShoppingListItem.count).to eq 0
    expect(Lot.count).to eq 1
  end

  # 開いている間に家族がチェックした行を、見ないまま消さない
  it "フォームに出ていなかった自由入力の行は残す" do
    entry = checked_entry(create(:item))
    later = create(:shopping_list_item, :free_text, :checked, added_by: user)

    result = described_class.call(purchase: purchase_for([ entry ]), user: user)

    expect(result.free_text_count).to eq 0
    expect(ShoppingListItem.pluck(:id)).to eq [ later.id ]
  end

  # 数量の上書きだけが残った行を放っておくと、数か月後に古い上書きが復活する
  it "購入した品目の行は、他の人が作り直していても片づく" do
    item = create(:item)
    entry = checked_entry(item)
    purchase = purchase_for([ entry ])
    # ロックの前に消えて作り直されたわけではなく、数量の上書きが足された場合
    entry.update!(quantity: 9)

    described_class.call(purchase: purchase, user: user)

    expect(ShoppingListItem.where(item_id: item.id)).to be_empty
  end

  it "チェックしていない行は残す" do
    entry = checked_entry(create(:item))
    other = create(:shopping_list_item, :manual, item: create(:item), added_by: user)

    described_class.call(purchase: purchase_for([ entry ]), user: user)

    expect(ShoppingListItem.pluck(:id)).to eq [ other.id ]
  end

  it "ついでに古い行 (アーカイブ済みの品目・期限切れのスヌーズ) を片づける" do
    entry = checked_entry(create(:item))
    create(:shopping_list_item, item: create(:item, :archived), added_by: user)
    create(:shopping_list_item, item: create(:item), added_by: user,
      snoozed_until: Date.current - 1)

    described_class.call(purchase: purchase_for([ entry ]), user: user)

    expect(ShoppingListItem.count).to eq 0
  end
end
