require "rails_helper"

RSpec.describe StockMovement, type: :model do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  describe "バリデーション" do
    it "quantity が 0 では保存できない (在庫が動かない記録は作らない)" do
      movement = build(:stock_movement, quantity: 0)

      expect(movement).not_to be_valid
      expect(movement.errors[:quantity]).to be_present
    end

    it "quantity は必須" do
      expect(build(:stock_movement, quantity: nil)).not_to be_valid
    end

    it "occurred_on は必須" do
      expect(build(:stock_movement, occurred_on: nil)).not_to be_valid
    end

    it "kind は purchase / usage / adjustment / disposal のいずれか" do
      movement = build(:stock_movement)
      movement.kind = "unknown"

      expect(movement).not_to be_valid
      expect(movement.errors[:kind]).to be_present
    end

    # 符号を取り違えると在庫が逆に動く。kind と符号の対応をモデルで固定する
    describe "kind と符号の対応" do
      it "purchase (入庫) は正でなければならない" do
        expect(build(:stock_movement, kind: :purchase, quantity: 1)).to be_valid
        expect(build(:stock_movement, kind: :purchase, quantity: -1)).not_to be_valid
      end

      it "usage (使用) は負でなければならない" do
        expect(build(:stock_movement, kind: :usage, quantity: -1)).to be_valid
        expect(build(:stock_movement, kind: :usage, quantity: 1)).not_to be_valid
      end

      it "disposal (廃棄) は負でなければならない" do
        expect(build(:stock_movement, kind: :disposal, quantity: -1, disposal_reason: :expired)).to be_valid
        expect(build(:stock_movement, kind: :disposal, quantity: 1, disposal_reason: :expired)).not_to be_valid
      end

      it "adjustment (調整) はプラスもマイナスもありうる" do
        expect(build(:stock_movement, kind: :adjustment, quantity: 2)).to be_valid
        expect(build(:stock_movement, kind: :adjustment, quantity: -2)).to be_valid
      end
    end

    describe "未来日" do
      it "今日の記録は保存できる" do
        travel_to Time.current.change(hour: 23, min: 30) do
          expect(build(:stock_movement, occurred_on: Date.current)).to be_valid
        end
      end

      it "明日の記録は保存できない" do
        travel_to Time.current.change(hour: 0, min: 10) do
          movement = build(:stock_movement, occurred_on: Date.current + 1)

          expect(movement).not_to be_valid
          expect(movement.errors[:occurred_on]).to be_present
        end
      end

      it "過去日の記録は保存できる" do
        expect(build(:stock_movement, occurred_on: Date.current - 30)).to be_valid
      end
    end

    # 理由の無い廃棄は「なんとなく減った」を廃棄で片づけた記録になり、
    # あとから何が起きたのか分からなくなる
    it "廃棄理由は廃棄の記録にだけ指定でき、廃棄には必ず要る" do
      expect(build(:stock_movement, kind: :usage, quantity: -1, disposal_reason: :expired)).not_to be_valid
      expect(build(:stock_movement, kind: :disposal, quantity: -1, disposal_reason: :expired)).to be_valid
      expect(build(:stock_movement, kind: :disposal, quantity: -1, disposal_reason: nil)).not_to be_valid
    end

    # 集計用に非正規化している item_id が lot とずれると、在庫の合計が壊れる
    it "item_id はロットの品目と一致していなければならない" do
      lot = create(:lot)
      movement = build(:stock_movement, lot: lot, item: create(:item))

      expect(movement).not_to be_valid
      expect(movement.errors[:item]).to be_present
    end

    describe "整数の上限" do
      it "数量は Lot::MAX_QUANTITY まで (プラスもマイナスも)" do
        expect(build(:stock_movement, kind: :purchase, quantity: Lot::MAX_QUANTITY)).to be_valid
        expect(build(:stock_movement, kind: :purchase, quantity: Lot::MAX_QUANTITY + 1)).not_to be_valid
        expect(build(:stock_movement, kind: :usage, quantity: -Lot::MAX_QUANTITY)).to be_valid
        expect(build(:stock_movement, kind: :usage, quantity: -Lot::MAX_QUANTITY - 1)).not_to be_valid
      end

      it "4 バイト整数をはみ出す数量でも例外にならず検証エラーになる" do
        movement = build(:stock_movement, quantity: 99_999_999_999)

        expect { movement.valid? }.not_to raise_error
        expect(movement).not_to be_valid
      end
    end
  end

  describe "DB の制約" do
    # 例外でテスト用トランザクションが壊れないよう SAVEPOINT の中で試す
    it "quantity を 0 にする UPDATE は check 制約で弾かれる" do
      movement = create(:stock_movement, quantity: 3)

      expect {
        described_class.transaction(requires_new: true) { movement.update_column(:quantity, 0) }
      }.to raise_error(ActiveRecord::StatementInvalid)

      expect(movement.reload.quantity).to eq 3
    end

    it "存在しないロットを指す UPDATE は外部キーで弾かれる" do
      movement = create(:stock_movement)

      expect {
        described_class.transaction(requires_new: true) { movement.update_column(:lot_id, nonexistent_uuid) }
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    # 非正規化した item_id がずれた行は、品目単位の再計算からも検査からも黙って落ちる。
    # (lot_id, item_id) の複合外部キーで DB 側から止める
    it "ロットと違う品目を指す UPDATE は複合外部キーで弾かれる" do
      movement = create(:stock_movement)

      expect {
        described_class.transaction(requires_new: true) {
          movement.update_column(:item_id, create(:item).id)
        }
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "ロットと違う品目を指す INSERT も複合外部キーで弾かれる" do
      lot = create(:lot)
      other = create(:item)

      expect {
        described_class.transaction(requires_new: true) {
          described_class.insert_all([ { item_id: other.id, lot_id: lot.id, kind: 0, quantity: 1,
                                         occurred_on: Date.current, user_id: lot.user_id,
                                         created_at: Time.current, updated_at: Time.current } ])
        }
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "入庫の記録を負にする UPDATE は check 制約で弾かれる" do
      movement = create(:stock_movement, kind: :purchase, quantity: 3)

      expect {
        described_class.transaction(requires_new: true) { movement.update_column(:quantity, -3) }
      }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "使用の記録を正にする UPDATE は check 制約で弾かれる" do
      movement = create(:stock_movement, kind: :usage, quantity: -3)

      expect {
        described_class.transaction(requires_new: true) { movement.update_column(:quantity, 3) }
      }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "廃棄以外に廃棄理由を入れる UPDATE は check 制約で弾かれる" do
      movement = create(:stock_movement, kind: :usage, quantity: -1)

      expect {
        described_class.transaction(requires_new: true) { movement.update_column(:disposal_reason, 0) }
      }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "理由を消す / 理由の無い廃棄にする UPDATE も check 制約で弾かれる" do
      movement = create(:stock_movement, kind: :disposal, quantity: -1, disposal_reason: :expired)

      expect {
        described_class.transaction(requires_new: true) { movement.update_column(:disposal_reason, nil) }
      }.to raise_error(ActiveRecord::StatementInvalid)

      usage = create(:stock_movement, kind: :usage, quantity: -1)
      expect {
        described_class.transaction(requires_new: true) {
          usage.update_column(:kind, described_class.kinds[:disposal])
        }
      }.to raise_error(ActiveRecord::StatementInvalid)
    end

    # ユーザーは物理削除しない方針 (docs/spec/01-domain-model.md 3 節)。
    # 記録者が消えると「誰が記録したか」が失われるので DB 側でも止める。
    # on_delete: :restrict は SQLSTATE 23001 (restrict_violation) なので、Rails は
    # 23503 だけを変換する InvalidForeignKey ではなく StatementInvalid を上げる
    it "記録者のユーザーは物理削除できない (外部キーで止まる)" do
      user = create(:user)
      create(:stock_movement, user: user)

      expect {
        described_class.transaction(requires_new: true) { user.delete }
      }.to raise_error(ActiveRecord::StatementInvalid, /RestrictViolation/)
    end
  end

  describe "ロットとの関連" do
    it "ロットを削除すると、その movement も消える" do
      lot = create(:lot, initial_quantity: 3)

      expect { lot.destroy }.to change { described_class.count }.by(-1)
    end
  end
end
