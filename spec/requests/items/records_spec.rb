require "rails_helper"

RSpec.describe "品目の記録の全履歴", type: :request do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:user) { create(:user) }
  let(:item) { create(:item, name: "トイレットペーパー", unit: "ロール") }

  before { sign_in user }

  describe "GET /items/:id/records" do
    it "使用・購入・廃棄が新しい順に並ぶ" do
      stock_up(item, 12, days_ago: 3)
      dispose(item, 1, days_ago: 2)
      record_usage(item, quantity: 2)

      get item_records_path(item)

      expect(response).to have_http_status(:ok)
      records = rendered_list("記録一覧")
      expect(records).to include "使った 2 ロール"
      expect(records).to include "廃棄"
      expect(records).to include "(期限切れ)"
      expect(records).to include "購入 12 ロール"
      expect(records.index("使った")).to be < records.index("廃棄")
      expect(records.index("廃棄")).to be < records.index("購入")
    end

    # 品目詳細は 10 件で切るので、続きを見るための画面 (docs/spec/03-screens.md 画面 3b)
    it "10 件を超えても全件出る" do
      record_usages(item, interval: 1, times: 12)

      get item_records_path(item)

      expect(rendered_list("記録一覧").scan("使った").size).to eq 12
    end

    # 行は品目詳細と同じ部分テンプレートなので、操作の導線もそのまま出る
    it "各行から編集や取り消しができる" do
      lot = stock_up(item, 12)
      usage = record_usage(item, quantity: 2)
      disposal = dispose(item, 1).movements.sole

      get item_records_path(item)

      expect(response.body).to include edit_usage_record_path(usage)
      expect(response.body).to include edit_lot_path(lot)
      expect(response.body).to include disposal_path(disposal)
    end

    # 1 行の描画は品目を渡して行うので、他の品目の記録が混ざっても単位は「ロール」で出る。
    # 数量で見分ける
    it "他の品目の記録は出ない" do
      record_usage(create(:item, name: "ティッシュ", unit: "箱"), quantity: 3)
      record_usage(item, quantity: 2)

      get item_records_path(item)

      expect(rendered_list("記録一覧")).to include "使った 2 ロール"
      expect(rendered_list("記録一覧")).not_to include "使った 3"
    end

    it "見出しに品目名が入り、品目詳細に戻れる" do
      get item_records_path(item)

      expect(response.parsed_body.at("h1").text).to include item.name
      expect(response.parsed_body.at("a[href='#{item_path(item)}']")).to be_present
    end

    it "記録が無ければその旨を出す" do
      get item_records_path(item)

      expect(response.body).to include "まだ記録がありません"
    end

    # 品目詳細と同じ扱い (アーカイブしても記録は残るので、履歴も見られる)
    it "アーカイブ済みの品目でも見られる" do
      archived = create(:item, :archived, name: "むかしの洗剤", unit: "本")
      record_usage(archived)

      get item_records_path(archived)

      expect(response).to have_http_status(:ok)
      expect(rendered_list("記録一覧")).to include "使った 1 本"
    end

    # 引けない品目 id が 404 になることは spec/requests/record_ids_spec.rb の表で見ている
  end
end
