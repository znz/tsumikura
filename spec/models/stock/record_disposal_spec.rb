require "rails_helper"

RSpec.describe Stock::RecordDisposal, type: :model do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:item) { create(:item, :tracks_expiry, name: "たまご", unit: "個") }
  let(:user) { create(:user) }

  def dispose(attributes = {})
    described_class.call(item: item, user: user, attributes: {
      quantity: 1, occurred_on: Date.current, disposal_reason: "expired"
    }.merge(attributes))
  end

  describe "廃棄の記録" do
    let!(:lot) { create(:lot, item: item, initial_quantity: 5) }

    it "kind: disposal の StockMovement が作られ、在庫が減る" do
      expect { dispose(quantity: 2) }.to change { StockMovement.count }.by(1)

      movement = StockMovement.order(:id).last
      expect(movement).to be_kind_disposal
      expect(movement.quantity).to eq(-2)
      expect(movement.disposal_reason).to eq "expired"
      expect(movement.user).to eq user
      expect(movement.occurred_on).to eq Date.current
      expect(item.reload.current_quantity).to eq 3
    end

    it "作られた movement を disposal.movements で受け取れる" do
      disposal = dispose(quantity: 2)

      expect(disposal.movements.size).to eq 1
      expect(disposal.errors).to be_empty
    end

    it "理由とメモも記録できる" do
      movement = dispose(disposal_reason: "damaged", note: "割れた").movements.sole

      expect(movement).to be_disposal_reason_damaged
      expect(movement.note).to eq "割れた"
    end

    it "過去日でも記録できる" do
      dispose(quantity: 2, occurred_on: Date.current - 3)

      expect(StockMovement.order(:id).last.occurred_on).to eq Date.current - 3
      expect(item.reload.current_quantity).to eq 3
    end

    # 廃棄は「使った」ではないので予測のアンカーを動かさない
    # (docs/spec/02-forecast.md 3 節)
    it "item.last_consumed_on は動かない" do
      dispose(quantity: 2)

      expect(item.reload.last_consumed_on).to be_nil
    end

    it "使い切ると depleted_at が入る" do
      dispose(quantity: 5)

      expect(lot.reload.depleted_at).to be_present
      expect(item.reload.current_quantity).to eq 0
    end
  end

  # 捨てるのは古いものからなので、使用 (期限切れは最後) とは順序が逆
  describe "引き当ての順番" do
    let!(:expired) { create(:lot, item: item, initial_quantity: 2, expires_on: Date.current - 1) }
    let!(:fresh) { create(:lot, item: item, initial_quantity: 5, expires_on: Date.current + 30) }

    it "ロットを指定しなければ期限切れから先に引く" do
      dispose(quantity: 2)

      expect(expired.reload.remaining_quantity).to eq 0
      expect(fresh.reload.remaining_quantity).to eq 5
    end

    it "足りなければ次のロットに分かれ、movement も分かれる" do
      disposal = dispose(quantity: 4)

      expect(disposal.movements.size).to eq 2
      expect(expired.reload.remaining_quantity).to eq 0
      expect(fresh.reload.remaining_quantity).to eq 3
    end

    it "ロットを指定すればそのロットから引く" do
      dispose(quantity: 2, lot_id: fresh.id)

      expect(fresh.reload.remaining_quantity).to eq 3
      expect(expired.reload.remaining_quantity).to eq 2
    end
  end

  describe "在庫を超える廃棄" do
    it "在庫記録より多い廃棄は記録できず、調整ロットも作らない" do
      create(:lot, item: item, initial_quantity: 2)

      disposal = nil
      expect { disposal = dispose(quantity: 3) }
        .not_to change { [ StockMovement.count, Lot.count ] }

      expect(disposal.movements).to be_nil
      expect(disposal.errors[:quantity]).to be_present
      expect(item.reload.current_quantity).to eq 2
    end

    it "在庫が 1 件も無ければ記録できない" do
      disposal = dispose(quantity: 1)

      expect(disposal.errors[:quantity]).to be_present
    end

    # 指定したロットに足りないぶんを黙って別のロットから引くと、
    # 「このロットを捨てた」という記録が別のロットの残数を減らしてしまう
    it "指定したロットの残りを超える廃棄は、他のロットから引かずに検証エラーにする" do
      small = create(:lot, item: item, initial_quantity: 1)
      other = create(:lot, item: item, initial_quantity: 9)

      disposal = nil
      expect { disposal = dispose(quantity: 3, lot_id: small.id) }
        .not_to change { StockMovement.count }

      expect(disposal.errors[:quantity]).to be_present
      expect(other.reload.remaining_quantity).to eq 9
    end
  end

  describe "保存できない入力" do
    before { create(:lot, item: item, initial_quantity: 5) }

    it "未来の日付では記録できない" do
      travel_to Time.zone.parse("2026-09-20 00:10") do
        disposal = nil
        expect { disposal = dispose(occurred_on: Date.current + 1) }
          .not_to change { StockMovement.count }
        expect(disposal.errors[:occurred_on]).to be_present
      end
    end

    it "数量が 0 や負では記録できない" do
      expect(dispose(quantity: 0).errors[:quantity]).to be_present
      expect(dispose(quantity: -1).errors[:quantity]).to be_present
    end

    it "4 バイト整数をはみ出す数量でも例外にならず検証エラーになる" do
      expect(dispose(quantity: 3_000_000_000).errors[:quantity]).to be_present
    end

    # ActiveModel の整数キャストは "1.5" を 1、"2abc" を 2 にしてしまう。
    # 黙って別の数量で記録しないよう、キャスト前の値で検査する
    it "小数や数字で始まる文字列は、黙って切り捨てず検証エラーになる" do
      expect(dispose(quantity: "1.5").errors[:quantity]).to be_present
      expect(dispose(quantity: "2abc").errors[:quantity]).to be_present
      expect(StockMovement.kind_disposal.count).to eq 0
    end

    # presence と numericality を 1 つの validates にまとめると allow_nil が
    # presence にも掛かり、数量が空のまま引き当てまで進んで 500 になる
    it "数量が空なら、台帳に触らずに「入力してください」だけを返す" do
      disposal = nil

      expect { disposal = dispose(quantity: "") }.not_to change { StockMovement.count }
      expect(disposal.errors[:quantity].size).to eq 1
      expect(disposal.movements).to be_nil
    end

    it "数量が送られてこなくても 例外にならない" do
      disposal = described_class.call(item: item, user: user, attributes: {
        occurred_on: Date.current, disposal_reason: "expired"
      })

      expect(disposal.errors[:quantity]).to be_present
    end

    it "ロット id も小数や数字で始まる文字列は検証エラーになる" do
      lot = create(:lot, item: item, initial_quantity: 5)

      expect(dispose(lot_id: "#{lot.id}.5").errors[:lot_id]).to be_present
      expect(dispose(lot_id: "#{lot.id}abc").errors[:lot_id]).to be_present
    end

    it "理由が無い / 知らない理由では記録できない" do
      expect(dispose(disposal_reason: nil).errors[:disposal_reason]).to be_present
      expect(dispose(disposal_reason: "unknown").errors[:disposal_reason]).to be_present
    end

    it "他の品目のロットは指定できず、そのロットも減らない" do
      other_lot = create(:lot, item: create(:item), initial_quantity: 5)

      disposal = nil
      expect { disposal = dispose(lot_id: other_lot.id) }.not_to change { StockMovement.count }

      expect(disposal.errors[:lot_id]).to be_present
      expect(other_lot.reload.remaining_quantity).to eq 5
    end

    # 8 バイト整数をはみ出す id を where に渡すと PG が範囲エラーを返して 500 になる
    it "8 バイト整数をはみ出すロット id でも例外にならず検証エラーになる" do
      expect(dispose(lot_id: 2**63).errors[:lot_id]).to be_present
    end
  end

  # 同じ品目への同時操作を直列化する。ロックより前に書き込むと取りこぼす
  it "最初の書き込みより前に品目を行ロックする" do
    # let は遅延評価なので、先に作っておかないと factory の INSERT まで記録してしまう
    item
    user
    create(:lot, item: item, initial_quantity: 5)

    statements = recorded_sql { dispose }

    expect(first_lock_index(statements)).not_to be_nil
    expect(first_lock_index(statements)).to be < first_write_index(statements)
  end

  it "ロックの前に読んだ古い在庫では引き当てない" do
    lot = create(:lot, item: item, initial_quantity: 5)
    item.lots.load
    create(:stock_movement, lot: Lot.find(lot.id), kind: :usage, quantity: -4)
    Stock::Recalculator.call(Item.find(item.id))

    disposal = dispose(quantity: 2)

    expect(disposal.errors[:quantity]).to be_present
    expect(item.reload.current_quantity).to eq 1
  end

  # 途中で例外が起きたときに movement だけが残ると在庫が狂う
  it "再計算が失敗したら movement も残らない (同一トランザクション)" do
    create(:lot, item: item, initial_quantity: 5)
    allow(Stock::Recalculator).to receive(:call).and_raise("boom")

    expect {
      expect { dispose }.to raise_error("boom")
    }.not_to change { StockMovement.count }
  end

  # Phase 7 のロットのガードが、廃棄でも効いていること
  it "廃棄の記録が紐づくロットは削除できない" do
    lot = create(:lot, item: item, initial_quantity: 5)
    dispose(quantity: 1)

    expect { Stock::DeleteLot.call(lot) }.not_to change { Lot.count }
    expect(lot.errors.full_messages.join).to include "削除できません"
  end
end
