require "rails_helper"

RSpec.describe "ワンタップ使用", type: :request do
  # 日付をまたぐ瞬間に走っても落ちないよう、時刻を固定する
  before { freeze_time }

  let(:user) { create(:user) }
  let(:item) { create(:item, name: "トイレットペーパー", unit: "ロール") }

  before { sign_in user }

  def quick_use(headers: {})
    post item_quick_use_path(item), headers: headers
  end

  describe "記録" do
    before { create(:lot, item: item, initial_quantity: 5) }

    it "数量 1・今日・用途なしで記録され、在庫が 1 減る" do
      expect { quick_use }.to change { UsageRecord.count }.by(1)
        .and change { StockMovement.count }.by(1)

      usage = UsageRecord.sole
      expect(usage.quantity).to eq 1
      expect(usage.used_on).to eq Date.current
      expect(usage.item_purpose).to be_nil
      expect(usage.user).to eq user
      expect(item.reload.current_quantity).to eq 4
    end

    it "FEFO で期限が近いロットから引かれる" do
      near = create(:lot, item: item, initial_quantity: 2, expires_on: Date.current + 1)

      quick_use

      expect(near.reload.remaining_quantity).to eq 1
    end
  end

  # JS があるとき: 一覧の行と品目詳細を描き直し、取り消し付きトーストを足す
  describe "Turbo Stream の応答" do
    let(:turbo_headers) { { "Accept" => "text/vnd.turbo-stream.html" } }

    before { create(:lot, item: item, initial_quantity: 5) }

    it "Turbo Stream で返る" do
      quick_use(headers: turbo_headers)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq "text/vnd.turbo-stream.html"
    end

    it "品目一覧の行と品目詳細とトーストを更新する" do
      quick_use(headers: turbo_headers)

      expect(response.body).to include %(target="item_#{item.id}")
      expect(response.body).to include %(target="detail_item_#{item.id}")
      expect(response.body).to include %(target="toasts")
    end

    # Turbo Stream の応答は parsed_body が文字列のままなので、自分で組み立てて読む
    it "更新後の在庫数が入っている" do
      quick_use(headers: turbo_headers)

      row = Nokogiri::HTML4::DocumentFragment.parse(response.body)
        .at("li##{ActionView::RecordIdentifier.dom_id(item)}")
      expect(row).to be_present
      expect(row.text).to include "4"
    end

    it "トーストに取り消しのボタンが入っている" do
      quick_use(headers: turbo_headers)

      expect(response.body).to include "取り消し"
      expect(response.body).to include usage_record_path(UsageRecord.sole)
    end

    it "フラッシュは残さない (次の画面に持ち越さない)" do
      quick_use(headers: turbo_headers)

      expect(flash[:toast]).to be_nil
    end

    # Turbo のスナップショットに残ると、「戻る」で復元された「取り消し」が
    # もう無い記録を消そうとしてしまう
    it "トーストは Turbo のスナップショットに残さない" do
      quick_use(headers: turbo_headers)

      expect(response.body).to include "data-turbo-temporary"
    end

    # 行にはステータスバッジが入っているので、記録した直後に判定も更新される
    it "更新後の行に要購入のステータスバッジが入っている" do
      item.update!(minimum_quantity: 5)

      quick_use(headers: turbo_headers)

      row = Nokogiri::HTML4::DocumentFragment.parse(response.body)
        .at("li##{ActionView::RecordIdentifier.dom_id(item)}")
      expect(row.text).to include "購入推奨"
    end

    it "ダッシュボードのクイック使用のタイルも差し替える" do
      quick_use(headers: turbo_headers)

      expect(response.body).to include %(target="quick_use_item_#{item.id}")
    end

    it "品目詳細の予測セクションも描き直す" do
      quick_use(headers: turbo_headers)

      expect(response.body).to include "要購入の予測"
    end

    it "在庫が足りなければ調整した旨をトーストに出す" do
      item.lots.destroy_all
      Stock::Recalculator.call(item)

      quick_use(headers: turbo_headers)

      expect(response.body).to include "在庫記録が不足していたため 1 ロール を調整しました"
    end
  end

  # JS が無いとき: 元の画面に戻して、フラッシュのトーストに取り消しを出す
  describe "HTML の応答 (JS 無し)" do
    before { create(:lot, item: item, initial_quantity: 5) }

    it "押した画面 (品目一覧) に戻る" do
      quick_use(headers: { "HTTP_REFERER" => items_url })

      expect(response).to redirect_to items_url
      expect(response).to have_http_status(:see_other)
    end

    it "Referer が無ければ品目詳細に戻る" do
      quick_use

      expect(response).to redirect_to item_path(item)
    end

    it "外部サイトの Referer は無視して品目詳細に戻る" do
      quick_use(headers: { "HTTP_REFERER" => "https://example.net/" })

      expect(response).to redirect_to item_path(item)
    end

    it "戻った画面に取り消しのボタンが出る" do
      quick_use(headers: { "HTTP_REFERER" => items_url })
      follow_redirect!

      expect(response.body).to include "使いました"
      expect(response.parsed_body.at("#toasts").text).to include "取り消し"
      expect(response.body).to include usage_record_path(UsageRecord.sole)
    end

    # トーストは #toasts の担当。通知の枠 (notice / alert) を空で出さない
    it "通知の枠は出さず、トーストだけを出す" do
      quick_use(headers: { "HTTP_REFERER" => items_url })
      follow_redirect!

      expect(response.parsed_body.at("#notice")).to be_nil
      expect(response.parsed_body.at("#alert")).to be_nil
      expect(response.parsed_body.at("#toasts").text).to include "使いました"
    end

    it "取り消すと在庫が戻る" do
      quick_use(headers: { "HTTP_REFERER" => items_url })

      expect {
        delete usage_record_path(UsageRecord.sole), headers: { "HTTP_REFERER" => items_url }
      }.to change { UsageRecord.count }.by(-1)

      expect(item.reload.current_quantity).to eq 5
    end
  end

  describe "引けない品目 id" do
    # URL の id は Base58 の 22 文字。読めない値・存在しない値・生の UUID のどれも 404
    it "404 で、記録も作られない" do
      [ 0, malformed_param, nonexistent_param, create(:item).id ].each do |item_id|
        expect { post item_quick_use_path(item_id: item_id) }.not_to change { UsageRecord.count }

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # 用途を管理する品目でも記録自体は成功させる (設計原則 3)。
  # 一覧の「使った」ボタンをフォームへの導線にしているのは画面側の判断
  it "用途を管理する品目に直接 POST しても用途なしで記録される" do
    purposes_item = create(:item, tracks_purposes: true)
    create(:lot, item: purposes_item, initial_quantity: 3)

    post item_quick_use_path(purposes_item)

    expect(purposes_item.reload.current_quantity).to eq 2
  end
end
