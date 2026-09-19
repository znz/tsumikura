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
