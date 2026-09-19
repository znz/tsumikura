require "rails_helper"

RSpec.describe Stock::Allocator, type: :model do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:item) { create(:item, name: "たまご", unit: "個", tracks_expiry: true) }
  let(:user) { create(:user) }

  def add_lot(quantity:, expires_on: nil, acquired_on: Date.current)
    create(:lot, item: item, initial_quantity: quantity,
      expires_on: expires_on, acquired_on: acquired_on)
  end

  def allocate(quantity, preferred_lot_id: nil, fallback_lot_ids: [], on: Date.current)
    described_class.call(item: item.reload, quantity: quantity, user: user, on: on,
      preferred_lot_id: preferred_lot_id, fallback_lot_ids: fallback_lot_ids)
  end

  # 引き当て結果を [[ロット, 数量], ...] で比べやすくする
  def pairs(result)
    result.allocations.map { |lot, quantity| [ lot.id, quantity ] }
  end

  describe "FEFO の順番" do
    it "期限が近いロットから引き当てる" do
      far = add_lot(quantity: 5, expires_on: Date.current + 30)
      near = add_lot(quantity: 5, expires_on: Date.current + 3)

      expect(pairs(allocate(1))).to eq [ [ near.id, 1 ] ]
      expect(far.reload.remaining_quantity).to eq 5
    end

    it "期限 nil のロットは期限つきロットの後に引き当てる" do
      dated = add_lot(quantity: 5, expires_on: Date.current + 30)
      undated = add_lot(quantity: 5, expires_on: nil)

      expect(pairs(allocate(6))).to eq [ [ dated.id, 5 ], [ undated.id, 1 ] ]
    end

    # 期限切れから先に引くと、期限切れを除いて数える要購入判定の在庫 q が減らず
    # 「使ったのに減らない」状態になる
    it "期限切れのロットは最後に引き当てる" do
      expired = add_lot(quantity: 5, expires_on: Date.current - 1, acquired_on: Date.current - 30)
      undated = add_lot(quantity: 5, expires_on: nil)
      dated = add_lot(quantity: 5, expires_on: Date.current + 30)

      expect(pairs(allocate(11))).to eq [ [ dated.id, 5 ], [ undated.id, 5 ], [ expired.id, 1 ] ]
    end

    it "今日が期限のロットはまだ期限切れではない (境界)" do
      today = add_lot(quantity: 5, expires_on: Date.current)
      undated = add_lot(quantity: 5, expires_on: nil)

      expect(pairs(allocate(1))).to eq [ [ today.id, 1 ] ]
      expect(undated.reload.remaining_quantity).to eq 5
    end

    it "期限が同じなら購入が古いロットから引き当てる" do
      newer = add_lot(quantity: 5, expires_on: Date.current + 5, acquired_on: Date.current)
      older = add_lot(quantity: 5, expires_on: Date.current + 5, acquired_on: Date.current - 10)

      expect(pairs(allocate(6))).to eq [ [ older.id, 5 ], [ newer.id, 1 ] ]
    end

    it "残 0 のロットは引き当てに使わない" do
      depleted = add_lot(quantity: 2, expires_on: Date.current + 1)
      create(:stock_movement, lot: depleted, kind: :usage, quantity: -2)
      Stock::Recalculator.call(item)
      available = add_lot(quantity: 5, expires_on: Date.current + 30)

      expect(pairs(allocate(1))).to eq [ [ available.id, 1 ] ]
    end

    it "他の品目のロットには触らない" do
      other_item = create(:item)
      other_lot = create(:lot, item: other_item, initial_quantity: 10)
      mine = add_lot(quantity: 5)

      expect(pairs(allocate(3))).to eq [ [ mine.id, 3 ] ]
      expect(other_lot.reload.remaining_quantity).to eq 10
    end
  end

  describe "分割" do
    it "在庫 5 のロットから 3 使うと、そのロットから 3 だけ引く" do
      lot = add_lot(quantity: 5)

      expect(pairs(allocate(3))).to eq [ [ lot.id, 3 ] ]
    end

    it "ロット A に 2・ロット B に 5 あるとき 4 使うと、A から 2・B から 2 に分かれる" do
      first = add_lot(quantity: 2, expires_on: Date.current + 1)
      second = add_lot(quantity: 5, expires_on: Date.current + 10)

      expect(pairs(allocate(4))).to eq [ [ first.id, 2 ], [ second.id, 2 ] ]
    end

    it "ちょうど使い切る数なら補填しない" do
      add_lot(quantity: 3)

      result = allocate(3)

      expect(result.shortage).to eq 0
      expect(result.compensating_lot).to be_nil
    end
  end

  # 在庫記録が足りなくても「使った」は必ず成功させる (設計原則 3)
  describe "在庫不足の補填" do
    it "在庫 2 に対して 3 使うと、不足 1 の調整ロットが 1 件作られる" do
      add_lot(quantity: 2)

      result = nil
      expect { result = allocate(3) }.to change { Lot.count }.by(1)

      expect(result.shortage).to eq 1
      expect(result.compensating_lot).to be_kind_adjustment
      expect(result.compensating_lot.initial_quantity).to eq 1
      expect(result.allocations.last).to eq [ result.compensating_lot, 1 ]
    end

    it "在庫が 1 件も無ければ全量を補填する" do
      result = allocate(3)

      expect(result.shortage).to eq 3
      expect(pairs(result)).to eq [ [ result.compensating_lot.id, 3 ] ]
    end

    it "補填の調整ロットは期限も価格も持たない (FEFO で最後に引かれる)" do
      result = allocate(1)

      expect(result.compensating_lot.expires_on).to be_nil
      expect(result.compensating_lot.price_yen).to be_nil
      expect(result.compensating_lot.user).to eq user
    end

    it "補填の調整ロットの日付は使用日になる" do
      result = allocate(1, on: Date.current - 3)

      expect(result.compensating_lot.acquired_on).to eq Date.current - 3
    end
  end

  describe "ロットの手動指定" do
    it "指定したロットから先に引く (FEFO より優先)" do
      near = add_lot(quantity: 5, expires_on: Date.current + 1)
      chosen = add_lot(quantity: 5, expires_on: Date.current + 30)

      expect(pairs(allocate(2, preferred_lot_id: chosen.id))).to eq [ [ chosen.id, 2 ] ]
      expect(near.reload.remaining_quantity).to eq 5
    end

    # 指定したロットに実在する在庫が残っているのに補填してしまうと、
    # 実在しない在庫が増えたうえ、残ったロットも使えないままになる
    it "指定したロットで足りない分は FEFO で続きを引く" do
      chosen = add_lot(quantity: 2, expires_on: Date.current + 30)
      near = add_lot(quantity: 5, expires_on: Date.current + 1)

      result = allocate(4, preferred_lot_id: chosen.id)

      expect(pairs(result)).to eq [ [ chosen.id, 2 ], [ near.id, 2 ] ]
      expect(result.shortage).to eq 0
    end

    it "指定したロットも他のロットも足りなければ補填する" do
      chosen = add_lot(quantity: 2)

      result = allocate(3, preferred_lot_id: chosen.id)

      expect(result.shortage).to eq 1
      expect(pairs(result)).to eq [ [ chosen.id, 2 ], [ result.compensating_lot.id, 1 ] ]
    end

    # フォームを開いている間に他の人が使い切ることがある。記録は成功させたうえで
    # 「指定どおりにできなかった」ことを呼び出し側に伝える (設計原則 3)
    it "残 0 のロットを指定されたら FEFO で引き、指定できなかったことを伝える" do
      depleted = add_lot(quantity: 1)
      create(:stock_movement, lot: depleted, kind: :usage, quantity: -1)
      Stock::Recalculator.call(item)
      available = add_lot(quantity: 5)

      result = allocate(1, preferred_lot_id: depleted.id)

      expect(pairs(result)).to eq [ [ available.id, 1 ] ]
      expect(result.preferred_lot_unavailable).to be true
    end

    it "指定したロットから引けたときは preferred_lot_unavailable は false" do
      chosen = add_lot(quantity: 5)

      expect(allocate(1, preferred_lot_id: chosen.id).preferred_lot_unavailable).to be false
    end

    it "指定が無ければ preferred_lot_unavailable は false" do
      add_lot(quantity: 5)

      expect(allocate(1).preferred_lot_unavailable).to be false
    end
  end

  # 編集で引き直すときは、元のロットを優先する (メモだけ直したら別のロットに移った、を防ぐ)
  describe "元のロットの優先 (fallback_lot_ids)" do
    it "FEFO より前に、元のロットから引く" do
      near = add_lot(quantity: 5, expires_on: Date.current + 1)
      previous = add_lot(quantity: 5, expires_on: Date.current + 30)

      expect(pairs(allocate(2, fallback_lot_ids: [ previous.id ]))).to eq [ [ previous.id, 2 ] ]
      expect(near.reload.remaining_quantity).to eq 5
    end

    it "複数のロットに分かれていた順番も保つ" do
      first = add_lot(quantity: 2, expires_on: Date.current + 30)
      second = add_lot(quantity: 5, expires_on: Date.current + 60)
      add_lot(quantity: 5, expires_on: Date.current + 1)

      expect(pairs(allocate(4, fallback_lot_ids: [ first.id, second.id ])))
        .to eq [ [ first.id, 2 ], [ second.id, 2 ] ]
    end

    it "消えたロットの id は無視して FEFO で続ける" do
      lot = add_lot(quantity: 5)

      expect(pairs(allocate(1, fallback_lot_ids: [ 0, lot.id ]))).to eq [ [ lot.id, 1 ] ]
    end

    it "手動で選んだロットは元のロットより優先される" do
      previous = add_lot(quantity: 5, expires_on: Date.current + 1)
      chosen = add_lot(quantity: 5, expires_on: Date.current + 30)

      expect(pairs(allocate(2, preferred_lot_id: chosen.id, fallback_lot_ids: [ previous.id ])))
        .to eq [ [ chosen.id, 2 ] ]
    end

    # 元のロットが見つからないのは「補填ロットが片づいた」だけなので警告しない
    it "元のロットが見つからなくても preferred_lot_unavailable にはしない" do
      add_lot(quantity: 5)

      expect(allocate(1, fallback_lot_ids: [ 0 ]).preferred_lot_unavailable).to be false
    end
  end

  # ロックの前に読んだ残数で引き当てると、ロック待ちの間に入った記録を取りこぼす。
  # 先読み済みの association をそのまま使う実装だとここが落ちる
  it "先読み済みのロットではなく、その場で読んだ残数で引き当てる" do
    lot = add_lot(quantity: 5)
    item.lots.load
    # 別の画面で先に 4 使われた状態を作る (こちらの item / lot は古いまま)
    create(:stock_movement, lot: Lot.find(lot.id), kind: :usage, quantity: -4)
    Stock::Recalculator.call(Item.find(item.id))

    result = described_class.call(item: item, quantity: 2, user: user, on: Date.current)

    expect(result.allocations.first).to eq [ lot, 1 ]
    expect(result.shortage).to eq 1
  end

  # 棚卸と廃棄は「実物がこれだけだった」という記録なので、足りない分を作ってはいけない
  # (docs/spec/01-domain-model.md 5 節 Phase 8 からの申し送り)
  describe "compensate: false" do
    it "不足しても調整ロットを作らず、引けた分だけ返す" do
      lot = add_lot(quantity: 2)

      result = nil
      expect {
        result = described_class.call(item: item, quantity: 5, user: user, on: Date.current,
          compensate: false)
      }.not_to change { Lot.count }

      expect(pairs(result)).to eq [ [ lot.id, 2 ] ]
      expect(result.shortage).to eq 3
      expect(result.compensating_lot).to be_nil
    end

    it "在庫が足りていれば既定と同じ結果になる" do
      lot = add_lot(quantity: 5)

      result = described_class.call(item: item, quantity: 5, user: user, on: Date.current,
        compensate: false)

      expect(pairs(result)).to eq [ [ lot.id, 5 ] ]
      expect(result.shortage).to eq 0
    end

    it "在庫が 1 件も無ければ引き当ては空になる" do
      result = described_class.call(item: item, quantity: 3, user: user, on: Date.current,
        compensate: false)

      expect(result.allocations).to be_empty
      expect(result.shortage).to eq 3
    end
  end

  # 廃棄は古いものから捨てるので、使用 (FEFO・期限切れは最後) とは順序が逆になる
  describe "expired_first: true" do
    it "期限切れロットから先に引く" do
      expired = add_lot(quantity: 2, expires_on: Date.current - 1)
      fresh = add_lot(quantity: 5, expires_on: Date.current + 1)

      result = described_class.call(item: item, quantity: 3, user: user, on: Date.current,
        compensate: false, expired_first: true)

      expect(pairs(result)).to eq [ [ expired.id, 2 ], [ fresh.id, 1 ] ]
    end

    it "期限切れが無ければ FEFO と同じ並び (期限が近い順 → 期限なし)" do
      near = add_lot(quantity: 1, expires_on: Date.current + 1)
      far = add_lot(quantity: 1, expires_on: Date.current + 30)
      none = add_lot(quantity: 1, expires_on: nil)

      result = described_class.call(item: item, quantity: 3, user: user, on: Date.current,
        compensate: false, expired_first: true)

      expect(pairs(result)).to eq [ [ near.id, 1 ], [ far.id, 1 ], [ none.id, 1 ] ]
    end

    it "期限切れが 2 件あれば、その中でも期限の古い順に引く" do
      older = add_lot(quantity: 1, expires_on: Date.current - 10)
      newer = add_lot(quantity: 1, expires_on: Date.current - 1)

      result = described_class.call(item: item, quantity: 2, user: user, on: Date.current,
        compensate: false, expired_first: true)

      expect(pairs(result)).to eq [ [ older.id, 1 ], [ newer.id, 1 ] ]
    end
  end
end
