require "rails_helper"

RSpec.describe Lot, type: :model do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  describe "バリデーション" do
    it "acquired_on は必須" do
      expect(build(:lot, acquired_on: nil)).not_to be_valid
    end

    it "initial_quantity は 1 以上でなければ保存できない" do
      expect(build(:lot, initial_quantity: 0)).not_to be_valid
      expect(build(:lot, initial_quantity: -1)).not_to be_valid
      expect(build(:lot, initial_quantity: 1)).to be_valid
    end

    it "kind は purchase / initial / adjustment のいずれか" do
      lot = build(:lot)
      lot.kind = "gift"

      expect(lot).not_to be_valid
      expect(lot.errors[:kind]).to be_present
    end

    it "期限・入数・パック数・金額・店舗・メモは任意" do
      lot = build(:lot, expires_on: nil, pack_size: nil, pack_count: nil,
        price_yen: nil, store: nil, note: nil)

      expect(lot).to be_valid
    end

    it "金額は 0 以上でなければ保存できない" do
      expect(build(:lot, price_yen: -1)).not_to be_valid
      expect(build(:lot, price_yen: 0)).to be_valid
    end

    describe "未来日" do
      it "今日の購入は保存できる" do
        travel_to Time.current.change(hour: 23, min: 30) do
          expect(build(:lot, acquired_on: Date.current)).to be_valid
        end
      end

      it "明日の購入は保存できない" do
        travel_to Time.current.change(hour: 0, min: 10) do
          lot = build(:lot, acquired_on: Date.current + 1)

          expect(lot).not_to be_valid
          expect(lot.errors[:acquired_on]).to be_present
        end
      end

      # CI (TZ=UTC) では 0:10 JST の Date.today は前日になる。
      # Date.current (Asia/Tokyo) で判定していないと、今日の購入が未来日として弾かれる
      it "0 時台 (JST) でも今日の購入は保存できる" do
        travel_to Time.current.change(hour: 0, min: 10) do
          expect(build(:lot, acquired_on: Date.current)).to be_valid
        end
      end

      # 期限は未来にあるのが普通なので、期限日には未来の制限を掛けない
      it "期限日は未来でよい" do
        expect(build(:lot, expires_on: Date.current + 365)).to be_valid
      end
    end

    describe "整数の上限" do
      it "数量は MAX_QUANTITY まで" do
        expect(build(:lot, initial_quantity: described_class::MAX_QUANTITY)).to be_valid
        expect(build(:lot, initial_quantity: described_class::MAX_QUANTITY + 1)).not_to be_valid
      end

      it "入数は MAX_QUANTITY まで、パック数は MAX_PACK_COUNT まで" do
        expect(build(:lot, pack_size: described_class::MAX_QUANTITY + 1, pack_count: 1)).not_to be_valid
        expect(build(:lot, pack_size: 1, pack_count: described_class::MAX_PACK_COUNT + 1)).not_to be_valid
      end

      it "金額は MAX_PRICE_YEN まで" do
        expect(build(:lot, price_yen: described_class::MAX_PRICE_YEN)).to be_valid
        expect(build(:lot, price_yen: described_class::MAX_PRICE_YEN + 1)).not_to be_valid
      end

      # 上限が無いと 4 バイト整数をはみ出した入力が書き込み時に ActiveModel::RangeError になり、
      # 検証エラー (422) ではなく 500 になる
      it "4 バイト整数をはみ出す値でも例外にならず検証エラーになる" do
        lot = build(:lot, initial_quantity: 99_999_999_999, price_yen: 99_999_999_999)

        expect { lot.valid? }.not_to raise_error
        expect(lot).not_to be_valid
      end

      it "入数 × パック数の積が上限を超えても例外にならず検証エラーになる" do
        lot = build(:lot, pack_size: described_class::MAX_QUANTITY, pack_count: described_class::MAX_PACK_COUNT)

        expect { lot.valid? }.not_to raise_error
        expect(lot).not_to be_valid
        expect(lot.errors[:initial_quantity]).to be_present
      end
    end

    # 家族 A がフォームを開いている間に B が店舗を削除した場合。
    # そのまま保存すると外部キー違反 (500) になるので、検証で捕まえる
    describe "削除済みの店舗を指す id" do
      it "削除済みの店舗 id では保存できない" do
        store = create(:store)
        store_id = store.id
        store.destroy

        lot = build(:lot, store_id: store_id)

        expect(lot).not_to be_valid
        expect(lot.errors[:store]).to be_present
      end

      it "id が 0 でも保存できない" do
        expect(build(:lot, store_id: 0)).not_to be_valid
      end

      it "店舗が空なら検証しない" do
        expect(build(:lot, store_id: nil)).to be_valid
      end
    end
  end

  describe "入数 × パック数" do
    # JS が無くても動くよう、入数とパック数と直接入力の数量がすべてサーバに届く前提で、
    # 「入数とパック数がそろっていればその積」を数量にする
    it "入数とパック数がそろっていれば、その積が数量になる" do
      lot = create(:lot, pack_size: 12, pack_count: 2, initial_quantity: 1)

      expect(lot.initial_quantity).to eq 24
    end

    it "入数だけなら直接入力の数量が使われ、入数は記録しない" do
      lot = create(:lot, pack_size: 12, pack_count: nil, initial_quantity: 5)

      expect(lot.initial_quantity).to eq 5
      expect(lot.pack_size).to be_nil
    end

    it "パック数だけなら直接入力の数量が使われ、パック数は記録しない" do
      lot = create(:lot, pack_size: nil, pack_count: 3, initial_quantity: 5)

      expect(lot.initial_quantity).to eq 5
      expect(lot.pack_count).to be_nil
    end

    it "どちらも空なら直接入力の数量が使われる" do
      lot = create(:lot, pack_size: nil, pack_count: nil, initial_quantity: 7)

      expect(lot.initial_quantity).to eq 7
    end

    it "入数とパック数がそろっていれば、そのまま記録に残る" do
      lot = create(:lot, pack_size: 12, pack_count: 2)

      expect(lot.pack_size).to eq 12
      expect(lot.pack_count).to eq 2
    end

    # JS があるときは隠れている側の入力欄が送られてこないので、DB に残った
    # 入数 × パック数で数量を上書きしてしまわないよう「書き換えたほう」を優先する
    describe "編集では書き換えたほうを優先する" do
      let(:lot) { create(:lot, pack_size: 12, pack_count: 2) } # 数量 24

      it "数量だけを書き換えると直接入力が勝ち、入数とパック数は消える" do
        lot.update!(initial_quantity: 20)

        expect(lot.reload.initial_quantity).to eq 20
        expect(lot.pack_size).to be_nil
        expect(lot.pack_count).to be_nil
      end

      it "入数・パック数もそのまま送って数量だけ書き換えたときも直接入力が勝つ" do
        lot.update!(pack_size: 12, pack_count: 2, initial_quantity: 20)

        expect(lot.reload.initial_quantity).to eq 20
        expect(lot.pack_size).to be_nil
      end

      it "入数かパック数を書き換えたら掛け算が勝つ" do
        lot.update!(pack_size: 6, pack_count: 3, initial_quantity: 24)

        expect(lot.reload.initial_quantity).to eq 18
        expect(lot.pack_size).to eq 6
      end

      it "どちらも書き換えなければ入数 × パック数のまま (何度保存しても変わらない)" do
        lot.update!(note: "メモだけ変える")
        lot.update!(note: "もう一度")

        lot.reload
        expect(lot.initial_quantity).to eq 24
        expect(lot.pack_size).to eq 12
        expect(lot.pack_count).to eq 2
      end
    end

    # 検証エラーのときに入数が消えると、フォームに戻ったときに入力が失われる
    it "保存できなかったときは入数・パック数の入力を消さない" do
      lot = build(:lot, pack_size: 12, pack_count: nil, initial_quantity: nil)

      expect(lot.save).to be false
      expect(lot.pack_size).to eq 12
    end
  end

  describe "単価" do
    it "単価は 税込合計 ÷ 入庫数量 (10 円以上は四捨五入して円単位)" do
      expect(build(:lot, price_yen: 456, initial_quantity: 12).unit_price_yen).to eq 38
    end

    it "端数は四捨五入する" do
      expect(build(:lot, price_yen: 100, initial_quantity: 3).unit_price_yen).to eq 33
      expect(build(:lot, price_yen: 101, initial_quantity: 3).unit_price_yen).to eq 34
    end

    # 100 枚 30 円のような品目で単価が 0 円に潰れないようにする
    it "10 円未満の単価は小数 1 桁まで出す" do
      expect(build(:lot, price_yen: 30, initial_quantity: 100).unit_price_yen).to eq 0.3
      expect(build(:lot, price_yen: 5, initial_quantity: 2).unit_price_yen).to eq 2.5
      expect(build(:lot, price_yen: 1, initial_quantity: 100).unit_price_yen).to eq 0.0
    end

    it "金額が無ければ単価も無い" do
      expect(build(:lot, price_yen: nil).unit_price_yen).to be_nil
    end

    describe ".average_unit_price_yen" do
      # 調整ロットは価格が nil なので、平均に混ぜると単価が歪む
      it "価格のあるロットだけで平均する" do
        item = create(:item)
        priced = create(:lot, item: item, price_yen: 456, initial_quantity: 12)
        cheaper = create(:lot, item: item, price_yen: 200, initial_quantity: 10)
        unpriced = create(:lot, item: item, price_yen: nil, initial_quantity: 100)

        # (456 + 200) / (12 + 10) = 29.8 -> 30
        expect(described_class.average_unit_price_yen([ priced, cheaper, unpriced ])).to eq 30
      end

      it "価格のあるロットが 1 件も無ければ nil" do
        item = create(:item)
        create(:lot, item: item, price_yen: nil)

        expect(described_class.average_unit_price_yen(item.lots)).to be_nil
      end

      it "ロットが 1 件も無ければ nil" do
        expect(described_class.average_unit_price_yen([])).to be_nil
      end

      # 何年も前の単価に引きずられないよう、直近の数件だけを見る
      it "価格のある直近 RECENT_PRICED_LOTS 件だけで平均する" do
        item = create(:item)
        old = create(:lot, item: item, price_yen: 1_000, initial_quantity: 1,
          acquired_on: Date.current - 100)
        recent = Array.new(described_class::RECENT_PRICED_LOTS) { |index|
          create(:lot, item: item, price_yen: 100, initial_quantity: 10,
            acquired_on: Date.current - index)
        }

        expect(described_class.average_unit_price_yen(recent + [ old ])).to eq 10
      end

      it "10 円未満の平均は小数 1 桁まで出す" do
        item = create(:item)
        lots = [ create(:lot, item: item, price_yen: 30, initial_quantity: 100) ]

        expect(described_class.average_unit_price_yen(lots)).to eq 0.3
      end
    end
  end

  describe "削除と参照整合性" do
    it "入庫の記録だけのロットは削除できる" do
      lot = create(:lot, initial_quantity: 3)

      expect(lot.destroy).to be_truthy
      expect(described_class.exists?(lot.id)).to be false
    end

    # 使用・廃棄が紐づくロットを消すと、使った記録まで消えてしまう
    it "使用の記録が紐づくロットは削除できない" do
      lot = create(:lot, initial_quantity: 3)
      create(:stock_movement, lot: lot, kind: :usage, quantity: -1)

      expect(lot.destroy).to be false
      expect(described_class.exists?(lot.id)).to be true
      expect(lot.errors[:base]).to be_present
    end

    it "廃棄の記録が紐づくロットは削除できない" do
      lot = create(:lot, initial_quantity: 3)
      create(:stock_movement, lot: lot, kind: :disposal, quantity: -1, disposal_reason: :expired)

      expect(lot.destroy).to be false
      expect(described_class.exists?(lot.id)).to be true
    end

    # 棚卸のマイナス差分を消すと、確定済みの棚卸の記録と消費ペースの分子まで消える
    it "棚卸のマイナス差分 (負の調整) が紐づくロットは削除できない" do
      lot = create(:lot, initial_quantity: 3)
      create(:stock_movement, lot: lot, kind: :adjustment, quantity: -1)

      expect(lot.destroy).to be false
      expect(described_class.exists?(lot.id)).to be true
    end

    it "プラスの調整だけなら削除できる" do
      lot = create(:lot, initial_quantity: 3)
      create(:stock_movement, lot: lot, kind: :adjustment, quantity: 2)

      expect(lot.destroy).to be_truthy
    end

    it "品目を削除するとロットも消える" do
      item = create(:item)
      create(:lot, item: item)

      expect { item.destroy }.to change { described_class.count }.by(-1)
    end

    # 品目の物理削除は画面には無いが、コンソール操作で中途半端に壊れないようにする
    # (ロットのガードで止まって movement だけが消える、という状態を作らない)
    it "消費済みのロットを持つ品目を削除しても、記録が半端に残らない" do
      item = create(:item)
      lot = create(:lot, item: item, initial_quantity: 3)
      create(:stock_movement, lot: lot, kind: :usage, quantity: -1)

      item.destroy

      expect(described_class.exists?(lot.id)).to eq Item.exists?(item.id)
      expect(StockMovement.where(item_id: item.id).exists?).to eq Item.exists?(item.id)
    end
  end

  describe "数量の編集" do
    it "既に使われた数より小さい数量には編集できない" do
      lot = create(:lot, initial_quantity: 12)
      create(:stock_movement, lot: lot, kind: :usage, quantity: -5)

      lot.initial_quantity = 4

      expect(lot).not_to be_valid
      expect(lot.errors[:initial_quantity]).to be_present
    end

    it "既に使われた数と同じなら編集できる (残 0 になる)" do
      lot = create(:lot, initial_quantity: 12)
      create(:stock_movement, lot: lot, kind: :usage, quantity: -5)

      lot.initial_quantity = 5

      expect(lot).to be_valid
    end

    it "使われていないロットは自由に減らせる" do
      lot = create(:lot, initial_quantity: 12)

      lot.initial_quantity = 1

      expect(lot).to be_valid
    end

    it "#consumed_quantity は出庫の合計 (絶対値)" do
      lot = create(:lot, initial_quantity: 12)
      create(:stock_movement, lot: lot, kind: :usage, quantity: -5)
      create(:stock_movement, lot: lot, kind: :disposal, quantity: -2, disposal_reason: :expired)

      expect(lot.consumed_quantity).to eq 7
    end
  end

  describe "DB の制約" do
    # 例外でテスト用トランザクションが壊れないよう SAVEPOINT の中で試す
    it "initial_quantity を 0 にする UPDATE は check 制約で弾かれる" do
      lot = create(:lot, initial_quantity: 3)

      expect {
        described_class.transaction(requires_new: true) { lot.update_column(:initial_quantity, 0) }
      }.to raise_error(ActiveRecord::StatementInvalid)

      expect(lot.reload.initial_quantity).to eq 3
    end

    # キャッシュ再計算 (Stock::Recalculator) が壊れたときの最後の守り
    it "remaining_quantity を負にする UPDATE は check 制約で弾かれる" do
      lot = create(:lot, initial_quantity: 3)

      expect {
        described_class.transaction(requires_new: true) { lot.update_column(:remaining_quantity, -1) }
      }.to raise_error(ActiveRecord::StatementInvalid)

      expect(lot.reload.remaining_quantity).to eq 3
    end

    # 入数・パック数は「両方あるか両方 NULL か」。片方だけ残ると
    # 「入数 × パック数で入れた」という記録として読めなくなる
    it "入数だけを NULL にする UPDATE は check 制約で弾かれる" do
      lot = create(:lot, pack_size: 12, pack_count: 2)

      expect {
        described_class.transaction(requires_new: true) { lot.update_column(:pack_size, nil) }
      }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "入数 × パック数と数量が合わない UPDATE は check 制約で弾かれる" do
      lot = create(:lot, pack_size: 12, pack_count: 2) # 数量 24

      expect {
        described_class.transaction(requires_new: true) { lot.update_column(:initial_quantity, 30) }
      }.to raise_error(ActiveRecord::StatementInvalid)

      expect(lot.reload.initial_quantity).to eq 24
    end

    # on_delete: :restrict は SQLSTATE 23001 (restrict_violation) なので、Rails は
    # 23503 だけを変換する InvalidForeignKey ではなく StatementInvalid を上げる
    it "記録者のユーザーは物理削除できない (外部キーで止まる)" do
      user = create(:user)
      create(:lot, user: user)

      expect {
        described_class.transaction(requires_new: true) { user.delete }
      }.to raise_error(ActiveRecord::StatementInvalid, /RestrictViolation/)
    end
  end

  describe "並び順 (FEFO)" do
    let(:item) { create(:item) }

    it "期限が近いロットから並ぶ" do
      late = create(:lot, item: item, expires_on: Date.current + 30)
      early = create(:lot, item: item, expires_on: Date.current + 3)

      expect(item.lots.fefo.to_a).to eq [ early, late ]
    end

    it "期限のないロットは期限つきロットの後に並ぶ" do
      undated = create(:lot, item: item, expires_on: nil)
      dated = create(:lot, item: item, expires_on: Date.current + 300)

      expect(item.lots.fefo.to_a).to eq [ dated, undated ]
    end

    # 期限切れロットから先に引くと、要購入判定の在庫 (期限切れを除く) が減らない
    it "期限切れのロットは最後に並ぶ" do
      expired = create(:lot, item: item, expires_on: Date.current - 1, acquired_on: Date.current - 30)
      undated = create(:lot, item: item, expires_on: nil)
      dated = create(:lot, item: item, expires_on: Date.current + 3)

      expect(item.lots.fefo.to_a).to eq [ dated, undated, expired ]
    end

    it "期限が同じなら購入が古いロットから並ぶ" do
      newer = create(:lot, item: item, expires_on: Date.current + 3, acquired_on: Date.current)
      older = create(:lot, item: item, expires_on: Date.current + 3, acquired_on: Date.current - 10)

      expect(item.lots.fefo.to_a).to eq [ older, newer ]
    end
  end

  describe "スコープ" do
    it ".available は残数が 1 以上のロットだけを返す" do
      item = create(:item)
      available = create(:lot, item: item, initial_quantity: 3)
      depleted = create(:lot, item: item, initial_quantity: 3)
      create(:stock_movement, lot: depleted, kind: :usage, quantity: -3)
      Stock::Recalculator.call(item)

      expect(item.lots.available).to contain_exactly(available)
    end

    it ".expired は今日より前に期限が切れたロットだけを返す" do
      item = create(:item)
      expired = create(:lot, item: item, expires_on: Date.current - 1)
      create(:lot, item: item, expires_on: Date.current)
      create(:lot, item: item, expires_on: nil)

      expect(item.lots.expired).to contain_exactly(expired)
    end
  end

  describe "#expired?" do
    it "今日より前に期限が切れていれば true (今日はまだ期限切れではない)" do
      expect(build(:lot, expires_on: Date.current - 1)).to be_expired
      expect(build(:lot, expires_on: Date.current)).not_to be_expired
      expect(build(:lot, expires_on: nil)).not_to be_expired
    end
  end

  # 廃棄は古いものから捨てるので、使用 (FEFO・期限切れは最後) とは順序が逆
  describe ".expired_first" do
    it "期限切れ → 期限が近い順 → 期限なし の順に並ぶ" do
      item = create(:item)
      expired = create(:lot, item: item, expires_on: Date.current - 1)
      near = create(:lot, item: item, expires_on: Date.current + 1)
      far = create(:lot, item: item, expires_on: Date.current + 30)
      none = create(:lot, item: item, expires_on: nil)

      expect(item.lots.expired_first.to_a).to eq [ expired, near, far, none ]
    end
  end

  # 差分 0 やプラス差分の明細には負の movement が付かないので、
  # 「出庫があるか」のガードだけでは止まらない
  describe "確定済みの棚卸で数えたロット" do
    let(:item) { create(:item) }
    let(:lot) { create(:lot, item: item, initial_quantity: 3) }

    # 確定済みの棚卸の明細は作れない (StockTakeEntry::Finalized) ので、
    # 実際の順番どおり「数えてから確定する」
    def entry_for(stock_take)
      create(:stock_take_entry, stock_take: stock_take, item: item, lot: lot,
        expected_quantity: 3, counted_quantity: 3)
    end

    def finalized_entry
      stock_take = create(:stock_take)
      entry_for(stock_take)
      stock_take.update_column(:finalized_at, Time.current)
      stock_take
    end

    it "確定済みの明細が紐づくロットは削除できない" do
      finalized_entry

      expect(lot.destroy).to be false
      expect(described_class.exists?(lot.id)).to be true
      expect(lot.errors.full_messages.join).to include "棚卸"
    end

    it "下書きの明細だけなら削除でき、明細も一緒に消える" do
      entry_for(create(:stock_take))

      expect { lot.destroy }.to change { StockTakeEntry.count }.by(-1)
      expect(described_class.exists?(lot.id)).to be false
    end

    it "品目ごと消すときは止めない (明細も一緒に消える)" do
      finalized_entry

      expect { item.destroy }.to change { described_class.count }.by(-1)
        .and change { StockTakeEntry.count }.by(-1)
    end
  end

  # 棚卸のプラス差分 (ロット別に数えた明細) は、そのロットに正の adjustment を足す。
  # 入庫の movement はあくまで購入・初期在庫の 1 行なので、区別できなければならない
  describe "#inbound_movement" do
    let(:item) { create(:item) }
    let(:lot) { create(:lot, item: item, initial_quantity: 3) }

    def stock_take_adjustment(quantity)
      stock_take = create(:stock_take)
      entry = create(:stock_take_entry, stock_take: stock_take, item: item, lot: lot,
        expected_quantity: 3, counted_quantity: 3 + quantity)
      create(:stock_movement, lot: lot, kind: :adjustment, quantity: quantity,
        stock_take_entry: entry)
      Stock::Recalculator.call(item)
    end

    it "購入の入庫を返す (棚卸のプラス差分は入庫ではない)" do
      stock_take_adjustment(2)

      expect(lot.inbound_movement).to be_kind_purchase
      expect(lot.inbound_movement.quantity).to eq 3
    end

    it "在庫不足の補填 (使用記録に紐づく正の adjustment) も入庫ではない" do
      empty = create(:item)
      Stock::RecordUsage.call(item: empty, user: create(:user),
        attributes: { quantity: 2, used_on: Date.current })

      expect(empty.lots.kind_adjustment.sole.inbound_movement).to be_nil
    end

    it "入庫の記録が無ければ nil" do
      expect(create(:lot, with_movement: false).inbound_movement).to be_nil
    end

    # 直すのは入庫の movement だけなので、棚卸で足された分はそのまま残る
    it "棚卸で +2 されたロットは、その分だけ小さい数量にも編集できる" do
      stock_take_adjustment(2)

      create(:stock_movement, lot: lot, kind: :usage, quantity: -4,
        usage_record: create(:usage_record, item: item, quantity: 4, with_movements: false))
      Stock::Recalculator.call(item)

      # Σ movements (3 + 2 − 4 = 1) − 旧入庫 (3) + 新数量 >= 0 なので 2 まで下げられる
      lot.reload
      expect(build_revision(lot, 2)).to be_valid
      expect(build_revision(lot, 1)).not_to be_valid
    end

    def build_revision(lot, quantity)
      lot.tap { |record| record.initial_quantity = quantity }
    end
  end
end
