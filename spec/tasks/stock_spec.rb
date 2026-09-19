require "rails_helper"
require "rake"

RSpec.describe "stock タスク", type: :task do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:item) { create(:item, name: "トイレットペーパー") }

  describe "stock:verify" do
    it "差異が無ければ正常終了し、その旨を表示する" do
      create(:lot, item: item, initial_quantity: 12)

      result = run_rake_task("stock:verify")

      expect(result.status).to eq 0
      expect(result.output).to include "差異はありません"
    end

    it "在庫が 1 件も無くても正常終了する" do
      item

      expect(run_rake_task("stock:verify")).to be_ok
    end

    it "ロットの残数がずれていると検出して異常終了する" do
      lot = create(:lot, item: item, initial_quantity: 12)
      lot.update_column(:remaining_quantity, 3)

      result = run_rake_task("stock:verify")

      expect(result.status).to eq 1
      expect(result.output).to include "残数"
      expect(result.output).to include "トイレットペーパー"
    end

    it "品目の在庫数がずれていると検出して異常終了する" do
      create(:lot, item: item, initial_quantity: 12)
      item.update_column(:current_quantity, 99)

      result = run_rake_task("stock:verify")

      expect(result.status).to eq 1
      expect(result.output).to include "在庫数"
      expect(result.output).to include "99"
    end

    it "記録開始日と最終消費日のずれも検出する" do
      lot = create(:lot, item: item, initial_quantity: 12)
      create(:stock_movement, lot: lot, kind: :usage, quantity: -1, occurred_on: Date.current)
      Stock::Recalculator.call(item)
      item.update_columns(tracking_started_on: nil, last_consumed_on: nil)

      result = run_rake_task("stock:verify")

      expect(result.status).to eq 1
      expect(result.output).to include "記録開始日"
      expect(result.output).to include "最終消費日"
    end

    it "残があるのに使い切った日時が入っていると検出する" do
      lot = create(:lot, item: item, initial_quantity: 12)
      lot.update_column(:depleted_at, Time.current)

      result = run_rake_task("stock:verify")

      expect(result.status).to eq 1
      expect(result.output).to include "使い切った日時"
    end

    it "残 0 なのに使い切った日時が入っていないと検出する" do
      lot = create(:lot, item: item, initial_quantity: 3)
      create(:stock_movement, lot: lot, kind: :usage, quantity: -3)
      Stock::Recalculator.call(item)
      lot.update_column(:depleted_at, nil)

      result = run_rake_task("stock:verify")

      expect(result.status).to eq 1
      expect(result.output).to include "使い切った日時"
    end

    # 入庫の movement とロットのずれは再計算では直らない (台帳が正なので在庫だけが静かに変わる)
    it "入庫の記録とロットの数量がずれていると検出する" do
      lot = create(:lot, item: item, initial_quantity: 12)
      lot.stock_movements.sole.update_column(:quantity, 8)

      result = run_rake_task("stock:verify")

      expect(result.status).to eq 1
      expect(result.output).to include "入庫の数量"
    end

    it "入庫の記録とロットの購入日がずれていると検出する" do
      lot = create(:lot, item: item, initial_quantity: 12)
      lot.stock_movements.sole.update_column(:occurred_on, Date.current - 5)

      result = run_rake_task("stock:verify")

      expect(result.status).to eq 1
      expect(result.output).to include "入庫の日付"
    end

    it "入庫の記録が無いロットを検出する" do
      lot = create(:lot, item: item, initial_quantity: 12)
      lot.stock_movements.delete_all

      result = run_rake_task("stock:verify")

      expect(result.status).to eq 1
      expect(result.output).to include "入庫の記録"
    end

    # 本来は (lot_id, item_id) の複合外部キーが止めるので、検査の側を確かめるために
    # この spec の中だけ外部キーを外す (テスト用トランザクションのロールバックで元に戻る)
    it "ロットと違う品目を指す記録を検出する" do
      lot = create(:lot, item: item, initial_quantity: 12)
      other = create(:item, name: "ティッシュ")
      ActiveRecord::Base.lease_connection.remove_foreign_key :stock_movements,
        column: [ :lot_id, :item_id ]
      lot.stock_movements.sole.update_column(:item_id, other.id)

      result = run_rake_task("stock:verify")

      expect(result.status).to eq 1
      expect(result.output).to include "在庫の記録"
      expect(result.output).to include "品目"
    end

    # usage_records.quantity と、紐づく出庫 movement の合計は二重管理になる。
    # ずれると「使った数」と在庫の減り方が食い違い、どちらが正か分からなくなる
    it "使用記録の数量と movement の合計のずれを検出する" do
      create(:lot, item: item, initial_quantity: 12)
      usage = create(:usage_record, item: item, quantity: 3)
      usage.update_column(:quantity, 9)

      result = run_rake_task("stock:verify")

      expect(result.status).to eq 1
      expect(result.output).to include "使用の数量"
      expect(result.output).to include "トイレットペーパー"
    end

    it "使用記録の日付と movement の日付のずれを検出する" do
      create(:lot, item: item, initial_quantity: 12)
      usage = create(:usage_record, item: item, quantity: 3)
      usage.stock_movements.sole.update_column(:occurred_on, Date.current - 5)

      result = run_rake_task("stock:verify")

      expect(result.status).to eq 1
      expect(result.output).to include "使用の日付"
    end

    it "movement が 1 件も無い使用記録を検出する" do
      create(:lot, item: item, initial_quantity: 12)
      create(:usage_record, item: item, quantity: 3, with_movements: false)

      result = run_rake_task("stock:verify")

      expect(result.status).to eq 1
      expect(result.output).to include "使用の数量"
    end

    # 在庫不足を補填した入庫 (正の adjustment) は「使った数」ではない
    it "在庫不足を補填した使用記録は差異にならない" do
      create(:usage_record, item: item, quantity: 3)

      expect(run_rake_task("stock:verify")).to be_ok
    end

    # 使用の movement が使用記録に紐づいていないと、どの操作で減ったのか分からず、
    # 使用記録の側からは編集も削除もできない行になる
    it "使用記録に紐づかない使用の記録を検出する" do
      lot = create(:lot, item: item, initial_quantity: 12)
      create(:stock_movement, lot: lot, kind: :usage, quantity: -1)
      Stock::Recalculator.call(item)

      result = run_rake_task("stock:verify")

      expect(result.status).to eq 1
      expect(result.output).to include "使用記録"
      expect(result.output).to include "トイレットペーパー"
    end

    it "使用記録に紐づく movement の種別の不整合を検出する" do
      create(:lot, item: item, initial_quantity: 12)
      usage = create(:usage_record, item: item, quantity: 2)
      # 廃棄には理由が要る (check 制約) ので、負の調整にすり替えて不整合を作る
      usage.stock_movements.sole.update_column(:kind, StockMovement.kinds[:adjustment])

      result = run_rake_task("stock:verify")

      expect(result.status).to eq 1
      expect(result.output).to include "使用記録に紐づく種別"
    end

    # 補填の調整ロットは、補填した分をそのまま使い切るので合計は必ず 0 になる
    it "補填の調整ロットに実在しない在庫が残っていると検出する" do
      usage = create(:usage_record, item: item, quantity: 3)
      usage.stock_movements.where(quantity: ...0).sole.delete
      Stock::Recalculator.call(item)

      result = run_rake_task("stock:verify")

      expect(result.status).to eq 1
      expect(result.output).to include "補填の調整ロット"
    end

    # 本来は (usage_record_id, item_id) の複合外部キーが止めるので、
    # 検査の側を確かめるためにこの spec の中だけ外部キーを外す
    it "使用記録と違う品目を指す記録を検出する" do
      create(:lot, item: item, initial_quantity: 12)
      usage = create(:usage_record, item: item, quantity: 2)
      other = create(:item, name: "ティッシュ")
      connection = ActiveRecord::Base.lease_connection
      connection.remove_foreign_key :stock_movements, column: [ :lot_id, :item_id ]
      connection.remove_foreign_key :stock_movements, column: [ :usage_record_id, :item_id ]
      usage.stock_movements.sole.update_column(:item_id, other.id)

      result = run_rake_task("stock:verify")

      expect(result.status).to eq 1
      expect(result.output).to include "使用記録の品目"
    end

    # 棚卸の差分は、紐づく movements の合計と一致していなければならない (二重管理のずれ)
    describe "棚卸" do
      let(:user) { create(:user) }

      def finalized_entry(counted:, expected_quantity: nil)
        stock_take = create(:stock_take, user: user)
        entry = create(:stock_take_entry, stock_take: stock_take, item: item,
          expected_quantity: expected_quantity || item.current_quantity, counted_quantity: counted)
        Stock::FinalizeStockTake.call(stock_take, user: user)
        entry.reload
      end

      it "確定した棚卸に差異が無ければ正常終了する" do
        create(:lot, item: item, initial_quantity: 12)
        finalized_entry(counted: 9)

        expect(run_rake_task("stock:verify")).to be_ok
      end

      it "確定済みの差分と movements の合計のずれを検出する" do
        create(:lot, item: item, initial_quantity: 12)
        entry = finalized_entry(counted: 9)
        entry.stock_movements.sole.update_column(:quantity, -1)
        Stock::Recalculator.call(item)

        result = run_rake_task("stock:verify")

        expect(result.status).to eq 1
        expect(result.output).to include "棚卸の差分"
      end

      it "確定済みなのに movement が無い非ゼロ差分の明細を検出する" do
        create(:lot, item: item, initial_quantity: 12)
        entry = finalized_entry(counted: 9)
        entry.stock_movements.sole.delete
        Stock::Recalculator.call(item)

        result = run_rake_task("stock:verify")

        expect(result.status).to eq 1
        expect(result.output).to include "棚卸の差分"
      end

      it "下書きなのに movement がある明細を検出する" do
        lot = create(:lot, item: item, initial_quantity: 12)
        stock_take = create(:stock_take, user: user)
        entry = create(:stock_take_entry, stock_take: stock_take, item: item,
          expected_quantity: 12, counted_quantity: 9)
        create(:stock_movement, lot: lot, kind: :adjustment, quantity: -3,
          stock_take_entry: entry)
        Stock::Recalculator.call(item)

        result = run_rake_task("stock:verify")

        expect(result.status).to eq 1
        expect(result.output).to include "下書きの在庫の記録"
      end

      it "実数未入力の明細は差異にならない" do
        create(:lot, item: item, initial_quantity: 12)
        stock_take = create(:stock_take, user: user)
        create(:stock_take_entry, stock_take: stock_take, item: item, counted_quantity: nil)
        # 1 件も数えていない棚卸は確定できないので、別の品目を 1 件だけ数えておく
        other = create(:item, name: "ティッシュ")
        create(:lot, item: other, initial_quantity: 5)
        create(:stock_take_entry, stock_take: stock_take, item: other,
          expected_quantity: 5, counted_quantity: 4)
        Stock::FinalizeStockTake.call(stock_take, user: user)

        expect(run_rake_task("stock:verify")).to be_ok
      end

      # 棚卸のプラス差分で作る調整ロットは、使用記録に紐づかない入庫を持つので
      # 「補填の調整ロット」の検査 (合計 0) には掛からない
      it "プラス差分の調整ロットは補填の検査に掛からない" do
        create(:lot, item: item, initial_quantity: 12)
        finalized_entry(counted: 15)

        expect(run_rake_task("stock:verify")).to be_ok
      end

      # 廃棄は kind: disposal なので「使用記録に紐づかない使用の記録」には当たらない
      it "廃棄の記録は差異にならない" do
        create(:lot, item: item, initial_quantity: 12)
        Stock::RecordDisposal.call(item: item, user: user, attributes: {
          quantity: 2, occurred_on: Date.current, disposal_reason: "expired"
        })

        expect(run_rake_task("stock:verify")).to be_ok
      end

      it "棚卸の movement の日付が棚卸日とずれていると検出する" do
        create(:lot, item: item, initial_quantity: 12)
        entry = finalized_entry(counted: 9)
        entry.stock_movements.sole.update_column(:occurred_on, Date.current - 1)
        Stock::Recalculator.call(item)

        result = run_rake_task("stock:verify")

        expect(result.status).to eq 1
        expect(result.output).to include "棚卸の日付"
      end

      it "ロット別に数えた明細の movement が別のロットに付いていると検出する" do
        lot = create(:lot, item: item, initial_quantity: 12)
        other = create(:lot, item: item, initial_quantity: 5)
        stock_take = create(:stock_take, user: user)
        entry = create(:stock_take_entry, stock_take: stock_take, item: item, lot: lot,
          expected_quantity: 12, counted_quantity: 9)
        Stock::FinalizeStockTake.call(stock_take, user: user)
        entry.stock_movements.sole.update_column(:lot_id, other.id)
        Stock::Recalculator.call(item)

        result = run_rake_task("stock:verify")

        expect(result.status).to eq 1
        expect(result.output).to include "棚卸で数えたロット"
      end

      it "棚卸の調整ロットと入庫 movement のずれを検出する" do
        create(:lot, item: item, initial_quantity: 12)
        finalized_entry(counted: 15)
        Lot.kind_adjustment.sole.update_columns(initial_quantity: 9, acquired_on: Date.current - 2)

        result = run_rake_task("stock:verify")

        expect(result.status).to eq 1
        expect(result.output).to include "棚卸の調整ロット"
        expect(result.output).to include "入庫の数量"
        expect(result.output).to include "入庫の日付"
      end

      # 調整は棚卸の明細 (棚卸の差分) か使用記録 (在庫不足の補填) に紐づく。
      # どちらでもない行はどの操作で在庫が動いたのか追えない
      it "出どころの分からない調整の記録を検出する" do
        lot = create(:lot, item: item, initial_quantity: 12)
        create(:stock_movement, lot: lot, kind: :adjustment, quantity: -2)
        Stock::Recalculator.call(item)

        result = run_rake_task("stock:verify")

        expect(result.status).to eq 1
        expect(result.output).to include "調整の出どころ"
      end

      it "棚卸の差分と在庫不足の補填は出どころありとみなす" do
        create(:lot, item: item, initial_quantity: 12)
        finalized_entry(counted: 9)
        create(:usage_record, item: create(:item), quantity: 3)   # 在庫 0 なので補填が入る

        expect(run_rake_task("stock:verify")).to be_ok
      end
    end

    it "ずれていない品目は出力に並ばない" do
      create(:lot, item: item, initial_quantity: 12)
      broken = create(:item, name: "ティッシュ")
      create(:lot, item: broken, initial_quantity: 5)
      broken.update_column(:current_quantity, 1)

      result = run_rake_task("stock:verify")

      expect(result.status).to eq 1
      expect(result.output).to include "ティッシュ"
      expect(result.output).not_to include "トイレットペーパー"
    end
  end

  describe "stock:recalculate" do
    it "全品目のキャッシュを台帳から直す" do
      create(:lot, item: item, initial_quantity: 12)
      other = create(:item)
      create(:lot, item: other, initial_quantity: 5)
      item.update_column(:current_quantity, 0)
      other.update_column(:current_quantity, 99)

      run_rake_task("stock:recalculate")

      expect(item.reload.current_quantity).to eq 12
      expect(other.reload.current_quantity).to eq 5
    end

    it "ロットの残数も直る" do
      lot = create(:lot, item: item, initial_quantity: 12)
      lot.update_column(:remaining_quantity, 0)

      run_rake_task("stock:recalculate")

      expect(lot.reload.remaining_quantity).to eq 12
    end

    it "再計算したあとは stock:verify が通る" do
      lot = create(:lot, item: item, initial_quantity: 12)
      lot.update_column(:remaining_quantity, 3)
      item.update_column(:current_quantity, 3)

      run_rake_task("stock:recalculate")

      expect(run_rake_task("stock:verify")).to be_ok
    end

    it "件数を表示する" do
      item

      expect(run_rake_task("stock:recalculate").output).to include "1 件"
    end

    # 1 品目の失敗 (check 制約違反など) で全体が止まると、残りの品目が直せない
    it "直せない品目があっても他の品目は直し、最後に一覧を出して異常終了する" do
      broken = create(:item, name: "こわれた品目")
      broken_lot = create(:lot, item: broken, initial_quantity: 1)
      # 台帳の総和が負になるロット (残数の check 制約に引っかかる)
      create(:stock_movement, lot: broken_lot, kind: :usage, quantity: -5)

      create(:lot, item: item, initial_quantity: 12)
      item.update_column(:current_quantity, 0)

      result = run_rake_task("stock:recalculate")

      expect(result.status).to eq 1
      expect(result.output).to include "こわれた品目"
      expect(item.reload.current_quantity).to eq 12
    end
  end
end
