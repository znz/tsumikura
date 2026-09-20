require "spec_helper"

# 悪化の判定は DB にも Rails にも依存させない (docs/spec/04-notifications.md 4 節)。
# Rails のオートロードが効かないので、対象ファイルと順位表の出どころを直接読む
require_relative "../../../app/models/forecast/calculator"
require_relative "../../../app/models/expiry/status"
require_relative "../../../app/models/notifications/digest"

RSpec.describe Notifications::Digest do
  def entry(purchase: "ok", expiry: "fresh", id: 1, name: "トイレットペーパー", snoozed: false)
    described_class::Entry.new(item_id: id, name: name, purchase_status: purchase,
      expiry_status: expiry, snoozed: snoozed)
  end

  def previous(purchase: nil, expiry: nil, id: 1)
    { id => described_class::Previous.new(purchase_status: purchase, expiry_status: expiry) }
  end

  def purchase_names(summary)
    summary.purchase_items.map(&:name)
  end

  def expiry_names(summary)
    summary.expiry_items.map(&:name)
  end

  describe "順位表" do
    it "要購入の向きは Forecast::Calculator::RANK から取る" do
      expect(described_class::PURCHASE_RANK).to eq("unknown" => -1, "ok" => 0, "soon" => 1, "urgent" => 2)
    end

    it "期限の向きは Expiry::Status::RANK から取る" do
      expect(described_class::EXPIRY_RANK).to eq("fresh" => 0, "expiring_soon" => 1, "expired" => 2)
    end
  end

  describe "要購入の悪化" do
    it "前回の記録が無ければ unknown とみなすので、urgent は悪化になる" do
      summary = described_class.call(entries: [ entry(purchase: "urgent") ])

      expect(purchase_names(summary)).to eq [ "トイレットペーパー" ]
    end

    it "ok から urgent は悪化になる" do
      summary = described_class.call(entries: [ entry(purchase: "urgent") ], previous: previous(purchase: "ok"))

      expect(purchase_names(summary)).to eq [ "トイレットペーパー" ]
    end

    it "ok から soon は悪化になる" do
      summary = described_class.call(entries: [ entry(purchase: "soon") ], previous: previous(purchase: "ok"))

      expect(purchase_names(summary)).to eq [ "トイレットペーパー" ]
    end

    it "soon から urgent は悪化になる" do
      summary = described_class.call(entries: [ entry(purchase: "urgent") ], previous: previous(purchase: "soon"))

      expect(purchase_names(summary)).to eq [ "トイレットペーパー" ]
    end

    it "unknown から soon は悪化になる" do
      summary = described_class.call(entries: [ entry(purchase: "soon") ], previous: previous(purchase: "unknown"))

      expect(purchase_names(summary)).to eq [ "トイレットペーパー" ]
    end

    it "urgent のまま横ばいなら悪化ではない (2 日連続で鳴らさない)" do
      summary = described_class.call(entries: [ entry(purchase: "urgent") ], previous: previous(purchase: "urgent"))

      expect(summary).to be_empty
    end

    it "urgent から soon への改善は悪化ではない" do
      summary = described_class.call(entries: [ entry(purchase: "soon") ], previous: previous(purchase: "urgent"))

      expect(summary).to be_empty
    end

    it "urgent から ok への回復は通知しない" do
      summary = described_class.call(entries: [ entry(purchase: "ok") ], previous: previous(purchase: "urgent"))

      expect(summary).to be_empty
    end

    it "unknown から ok は悪化でも通知対象でもない" do
      summary = described_class.call(entries: [ entry(purchase: "ok") ], previous: previous(purchase: "unknown"))

      expect(summary).to be_empty
    end

    it "ok から unknown (判定できなくなった) は通知しない" do
      summary = described_class.call(entries: [ entry(purchase: "unknown") ], previous: previous(purchase: "ok"))

      expect(summary).to be_empty
    end

    it "回復したあとに悪化したら、また通知される" do
      recovered = described_class.call(entries: [ entry(purchase: "ok") ], previous: previous(purchase: "urgent"))
      again = described_class.call(entries: [ entry(purchase: "urgent") ], previous: previous(purchase: "ok"))

      expect(recovered).to be_empty
      expect(purchase_names(again)).to eq [ "トイレットペーパー" ]
    end

    it "「今回は買わない」で見送り中の品目は通知しない" do
      summary = described_class.call(entries: [ entry(purchase: "urgent", snoozed: true) ])

      expect(summary).to be_empty
    end

    it "見送り中でも期限の悪化は通知する (見送りは買い物の話なので)" do
      summary = described_class.call(entries: [ entry(purchase: "urgent", expiry: "expired", snoozed: true) ])

      expect(purchase_names(summary)).to be_empty
      expect(expiry_names(summary)).to eq [ "トイレットペーパー" ]
    end
  end

  describe "期限の悪化" do
    it "前回の記録が無ければ fresh とみなすので、expiring_soon は悪化になる" do
      summary = described_class.call(entries: [ entry(expiry: "expiring_soon") ])

      expect(expiry_names(summary)).to eq [ "トイレットペーパー" ]
    end

    it "expiring_soon から expired は悪化になる" do
      summary = described_class.call(entries: [ entry(expiry: "expired") ], previous: previous(expiry: "expiring_soon"))

      expect(expiry_names(summary)).to eq [ "トイレットペーパー" ]
    end

    it "expired のまま横ばいなら悪化ではない" do
      summary = described_class.call(entries: [ entry(expiry: "expired") ], previous: previous(expiry: "expired"))

      expect(summary).to be_empty
    end

    it "expired から expiring_soon への改善 (期限切れを捨てた) は通知しない" do
      summary = described_class.call(entries: [ entry(expiry: "expiring_soon") ], previous: previous(expiry: "expired"))

      expect(summary).to be_empty
    end

    it "fresh に戻っただけでは通知しない" do
      summary = described_class.call(entries: [ entry(expiry: "fresh") ], previous: previous(expiry: "expired"))

      expect(summary).to be_empty
    end
  end

  describe "status の扱い" do
    it "Symbol で渡しても文字列で比べる (item_alert_states には文字列で入る)" do
      summary = described_class.call(entries: [ entry(purchase: :urgent) ], previous: previous(purchase: "urgent"))

      expect(summary).to be_empty
    end

    it "Entry は status を文字列にそろえる" do
      expect(entry(purchase: :soon, expiry: :expired)).to have_attributes(
        purchase_status: "soon", expiry_status: "expired"
      )
    end

    it "前回の値が nil / 空文字なら unknown・fresh とみなす" do
      expect(described_class::Previous.new).to have_attributes(purchase_status: "unknown", expiry_status: "fresh")
      expect(described_class::Previous.new(purchase_status: "", expiry_status: ""))
        .to have_attributes(purchase_status: "unknown", expiry_status: "fresh")
    end

    it "知らない status が入っていても例外にせず、通知しないだけにする" do
      summary = described_class.call(
        entries: [ entry(purchase: "たぶん昔の値", expiry: "むかしのち") ],
        previous: previous(purchase: "これも知らない値")
      )

      expect(summary).to be_empty
    end

    it "前回の値だけが知らない値なら、いちばん良い状態とみなして比べる" do
      summary = described_class.call(entries: [ entry(purchase: "urgent") ], previous: previous(purchase: "むかしのち"))

      expect(purchase_names(summary)).to eq [ "トイレットペーパー" ]
    end
  end

  describe "種別の ON/OFF" do
    let(:summary) do
      described_class.call(entries: [
        entry(id: 1, name: "トイレットペーパー", purchase: "urgent"),
        entry(id: 2, name: "牛乳", expiry: "expiring_soon")
      ])
    end

    it "購入だけを受け取る人には期限の悪化を数えない" do
      narrowed = summary.only(purchases: true, expiries: false)

      expect(purchase_names(narrowed)).to eq [ "トイレットペーパー" ]
      expect(expiry_names(narrowed)).to be_empty
    end

    it "期限だけを受け取る人には購入の悪化を数えない" do
      narrowed = summary.only(purchases: false, expiries: true)

      expect(purchase_names(narrowed)).to be_empty
      expect(expiry_names(narrowed)).to eq [ "牛乳" ]
    end

    it "両方 OFF の人にとっては 0 件になる" do
      expect(summary.only(purchases: false, expiries: false)).to be_empty
    end

    it "絞っても元の Summary は変わらない" do
      summary.only(purchases: false, expiries: false)

      expect(summary.any?).to be true
    end
  end

  describe "本文" do
    # ラベルは画面と同じ語彙を呼び出し側 (ジョブ) が I18n から渡す
    let(:purchase_labels) { { "urgent" => "購入推奨", "soon" => "そろそろ購入" } }
    let(:expiry_labels) { { "expired" => "期限切れ", "expiring_soon" => "期限間近" } }

    def body_of(summary)
      summary.body(purchase_labels: purchase_labels, expiry_labels: expiry_labels)
    end

    it "ステータスごとの内訳を、悪い順に並べる" do
      summary = described_class.call(entries: [
        entry(id: 1, name: "トイレットペーパー", purchase: "urgent"),
        entry(id: 2, name: "せっけん", purchase: "soon"),
        entry(id: 3, name: "ラップ", purchase: "soon"),
        entry(id: 4, name: "牛乳", expiry: "expired"),
        entry(id: 5, name: "ヨーグルト", expiry: "expiring_soon")
      ])

      expect(body_of(summary))
        .to eq "購入推奨 1 件・そろそろ購入 2 件・期限切れ 1 件・期限間近 1 件 — トイレットペーパー ほか"
    end

    it "0 件の内訳は並べない (soon を「購入推奨」と言わない)" do
      summary = described_class.call(entries: [ entry(name: "せっけん", purchase: "soon") ])

      expect(body_of(summary)).to eq "そろそろ購入 1 件 — せっけん"
    end

    it "期限切れを「期限間近」と言わない" do
      summary = described_class.call(entries: [ entry(name: "牛乳", expiry: "expired") ])

      expect(body_of(summary)).to eq "期限切れ 1 件 — 牛乳"
    end

    it "1 件だけなら「ほか」を付けない" do
      summary = described_class.call(entries: [ entry(purchase: "urgent") ])

      expect(body_of(summary)).to eq "購入推奨 1 件 — トイレットペーパー"
    end

    it "購入と期限の両方で悪化した品目は、名前を 1 度しか出さない" do
      summary = described_class.call(entries: [ entry(purchase: "urgent", expiry: "expired") ])

      expect(body_of(summary)).to eq "購入推奨 1 件・期限切れ 1 件 — トイレットペーパー"
    end

    it "種別で絞ったあとの内訳だけを並べる" do
      summary = described_class.call(entries: [
        entry(id: 1, name: "トイレットペーパー", purchase: "urgent"),
        entry(id: 2, name: "牛乳", expiry: "expired")
      ])

      expect(body_of(summary.only(purchases: false, expiries: true))).to eq "期限切れ 1 件 — 牛乳"
    end
  end

  describe ".states (item_alert_states に書き戻す値)" do
    # ActiveSupport は読み込んでいないので sole は使えない (この spec は spec_helper だけで回す)
    def state_for(entries, previous = {})
      described_class.states(entries: entries, previous: previous).fetch(0)
    end

    it "ふつうの品目は現在値をそのまま記録する" do
      state = state_for([ entry(purchase: "urgent", expiry: "expired") ])

      expect(state).to have_attributes(item_id: 1, purchase_status: "urgent", expiry_status: "expired")
    end

    it "見送り中の品目の要購入ステータスは前回値のまま据え置く" do
      # 現在値 (urgent) で記録すると、見送りが切れたあとも「横ばい」になって二度と通知されない
      state = state_for([ entry(purchase: "urgent", snoozed: true) ], previous(purchase: "ok"))

      expect(state.purchase_status).to eq "ok"
    end

    it "見送り中でも期限のステータスは現在値で記録する (見送りは買い物の話なので)" do
      state = state_for([ entry(purchase: "urgent", expiry: "expired", snoozed: true) ],
        previous(purchase: "ok", expiry: "fresh"))

      expect(state).to have_attributes(purchase_status: "ok", expiry_status: "expired")
    end

    it "前回の記録が無い見送り中の品目は unknown のまま据え置く" do
      state = state_for([ entry(purchase: "urgent", snoozed: true) ])

      expect(state.purchase_status).to eq "unknown"
    end

    it "見送りが切れた翌朝には通知される (据え置いた値と比べるため)" do
      snoozed = described_class.states(
        entries: [ entry(purchase: "urgent", snoozed: true) ], previous: previous(purchase: "ok")
      ).fetch(0)
      next_morning = described_class.call(
        entries: [ entry(purchase: "urgent") ],
        previous: { 1 => described_class::Previous.new(purchase_status: snoozed.purchase_status,
                                                       expiry_status: snoozed.expiry_status) }
      )

      expect(purchase_names(next_morning)).to eq [ "トイレットペーパー" ]
    end

    it "entries が空なら空を返す" do
      expect(described_class.states(entries: [])).to eq []
    end
  end

  describe "#empty? / #any?" do
    it "悪化が 0 件なら empty" do
      summary = described_class.call(entries: [ entry ])

      expect(summary).to be_empty
      expect(summary.any?).to be false
    end

    it "entries が空でも落ちない" do
      expect(described_class.call(entries: [])).to be_empty
    end
  end
end
