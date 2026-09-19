# 予測と要購入判定

[概要](00-overview.md) / [データモデル](01-domain-model.md) / [画面](03-screens.md)

## 1. 全体像

要購入判定は 2 系統あり、**悪い方を採用**する。

1. **消費ペースによる判定** — 実績から消費ペースを出し、「在庫切れ予測日 (`need_by_on`) まで何日か」で 3 段階に分ける。
2. **最低在庫数による判定** — 品目に `minimum_quantity` が設定されていれば、在庫との比較で 3 段階に分ける。

どちらも判定できないときは `unknown` (判定不能) とし、ダッシュボードの要購入件数には数えない。例外として、ペースが分からず在庫が 0 の品目は `urgent` にする (7 節)。予測はあくまで参考値であり、確信が持てないときは黙る (設計原則 4)。

| ステータス | 表示 | 意味 |
|---|---|---|
| `ok` | 購入不要 | 当面は足りる |
| `soon` | そろそろ購入 | 次かその次の買い物で買えばよい |
| `urgent` | 購入推奨 | 次の買い物で必ず買う |
| `unknown` | — | データ不足で判定しない |

## 2. 入力値

| 記号 | 名前 | 定義 |
|---|---|---|
| `today` | 今日 | `Date.current` (JST) |
| `q` | 在庫 | 現在庫から**期限切れロットの残数を除いた数**。期限切れの保存食を備蓄に数えないため |
| 消費イベント | — | **消費のあった日**。同じ日に複数の記録があっても 1 件と数える (1 回の使用が FEFO で複数の `stock_movements` に分かれても、同じ日に 2 回記録しても 1 件) |
| `anchor` | アンカー | 最後の消費イベント日 (`items.last_consumed_on`)。消費イベントが無ければ `items.tracking_started_on`。どちらも無ければ `nil` |
| `consumed` | 窓内の消費量 | 半開区間 `(window_start, today]` にある `usage` の数量 + **負の** `adjustment` の絶対値の合計。窓の開始日当日の消費は含めない |
| `event_count` | 消費イベント数 | 閉区間 `[window_start, today]` にある消費イベントの数。**窓の開始日当日も数える** (3 節) |
| `observed_days` | 観測日数 | `window_end − window_start` (3 節) |
| `u` | 1 回あたりの使用数 | `(window_start, today]` の `usage_records.quantity` の**中央値**。記録が無ければ 1。中央値が小数になる場合は四捨五入し、最低 1 とする |
| `minimum` | 最低在庫数 | `items.minimum_quantity` (任意) |

消費に**含めるもの**: 使用記録 (`usage`)、棚卸のマイナス差分 (`adjustment` かつ負)。
消費に**含めないもの**: 廃棄 (`disposal`)、購入 (`purchase`)、棚卸のプラス差分 (`adjustment` かつ正)。

- 廃棄を含めない理由: 期限切れ廃棄は「使った」ではない。含めるとペースが過大になり、買いすぎを招く。
- 在庫不足時の自動補填で作られる調整ロット (プラス) も分子に入らないので、予測は歪まない。
- 使用日・棚卸日・廃棄日に**未来の日付は指定できない** (バリデーション)。したがって消費イベントは常に `today` 以前にある。

## 3. 集計窓

窓は固定日数ではなく、**消費イベントが少ない品目では自動的に過去へ伸びる**。年に 1〜2 回しか使わない品目 (くん煙剤、防災用品) を固定 90 日窓で見ると、消費が 0 件になって永久に判定できないためである。

```
# 直近 window_events (=5) 件目の消費イベント日。
# 消費イベントが 5 件未満なら最古の消費イベント日。1 件も無ければ nil
nth_event_on = ...

candidate    = [today - window_min_days, nth_event_on].compact.min   # 既定では today - 90 日か、それより古い nth_event_on
floor_on     = [tracking_started_on, today - window_max_days].compact.max   # 既定では today - 730 日が下限
window_start = [candidate, floor_on].max

# 窓の開始が消費イベント日で決まったときは、観測の終わりも消費イベント日 (anchor) に揃える
window_end    = (window_start == nth_event_on) ? anchor : today
observed_days = window_end - window_start
```

窓は**半開区間 `(window_start, today]`** とし、窓の開始日当日の消費は `consumed` に含めない。

- 開始日を含めない理由: 窓の開始が消費イベント日のとき、そのイベントは最初の間隔の**始点**であって、窓の中で消費された量ではない。これを数えると「5 件 ÷ 4 間隔分の日数」になり、ペースを 5/4 倍に過大評価する。
- `window_end` を `anchor` に揃える理由: 最後の消費から今日までの空白は、まだ終わっていない間隔である。これを分母に入れると、次の使用が近づくほどペースを過小評価し、肝心の時期に予測日が後ろへ逃げる (120 日間隔の品目で、次の使用予定日になっても `days_left = 30` と出る)。始点と終点をどちらも消費イベント日にすれば、完結した間隔だけでペースを測れる。
- 窓の開始が `today - 90` や下限 (`floor_on`) で決まったときは、窓の両端とも消費イベント日ではない。この場合は通常の「期間内の消費量 ÷ 期間の日数」として `window_end = today` のまま計算する。
- `tracking_started_on` (その品目の最初の在庫イベント日) で打ち切るのが肝。使い始めて 10 日の品目を 90 で割ると、ペースが 1/9 に過小評価されて「購入不要」と出てしまう。在庫イベントが 1 件も無い品目では `nil` であり、下限は `today - 730` だけになる。
- 上限 730 日で打ち切るのは、2 年より前の生活パターンを今の予測に持ち込まないため。
- `consumed` と `u` は `(window_start, today]` で集計する。未来日の記録は無いので、`(window_start, window_end]` で集計しても同じ値になる。

## 4. 消費ペース

```
pace = Rational(consumed, observed_days)      # 1 日あたりの消費量
```

判定不能 (`unknown`) になる条件 (上から順に評価する):

| 条件 | 結果 |
|---|---|
| `estimation_mode` が `none` | `unknown` (予測を止めたい品目) |
| `estimation_mode` が `manual` | 8 節。`manual_interval_days` が未設定、または `anchor` が `nil` なら `unknown` |
| `anchor` が `nil` | `unknown` (起点が無いと在庫切れ予測日を出せない) |
| `event_count < min_samples` (既定 2) | `unknown` (消費イベントが 2 件無いと間隔を 1 つも測れない) |
| `observed_days < min_observed_days` (既定 14) | `unknown` (観測が浅すぎる) |
| それ以外 | `pace = consumed / observed_days` |

- `event_count` は窓の開始日当日を含めて数える。知りたいのは「間隔が 1 つ以上測れるか」であり、窓の開始日にある消費イベントは最初の間隔の始点として有効だからである。消費イベントが全部で 2 件しかなく、古い方が窓の開始になる品目でも `event_count = 2` となり、その 1 間隔からペースが出る。
- `event_count >= 2` なら、開始日より後に消費イベントが必ず 1 件以上あるので `consumed > 0` が保証される。「ペースは分かっているが 0」という状態は起こらず、ゼロ除算も起きない。
- `event_count >= 2` なら理屈のうえでは `anchor` も必ずある。それでも `auto` で `anchor` が `nil` のときを `unknown` にするのは、`anchor` が `items.last_consumed_on` という**キャッシュ列**、`event_count` が `stock_movements` の**集計**で、取得元が違うためである。キャッシュがずれて起点だけ欠けたときに例外を投げるのではなく黙る (設計原則 4)。
- `observed_days` が 14 を下回るのは、`tracking_started_on` が 14 日以内の新しい品目か、測れた間隔の合計が 14 日に満たない品目である。どちらも極端なペースが出やすいので判定しない。
- ペースは有理数 (`Rational`) で持つ。浮動小数の誤差で切り上げが 1 日ずれるのを避けるため。

判定不能なら**最低在庫数だけで判定する** (在庫 0 のときは 7 節の `by_stockout` も効く)。UI では「データ収集中 — 使用記録がたまると予測を開始します」と出す。

## 5. 在庫切れ予測日 (`need_by_on`)

```
uses_left  = q / u                                       # 整数除算。在庫であと何回まるごと使えるか
need_by_on = anchor + ((uses_left + 1) * u / pace).ceil  # 日数を切り上げ
need_by_on = today if need_by_on < today

days_left = need_by_on - today     # 0 以上
```

意味は「**次に使いたいときに未使用在庫が無い日**」= その日までに買っておくべき期限。

### なぜ `今日 + 在庫 ÷ ペース` にしないのか

1. **使わない日が続くと予測日が後ろへずれる。** 今日を起点にすると、1 週間使わなかっただけで予測日も 1 週間後ろへ動き、いつまでも「まだ買わなくていい」と言い続ける。実際には次に使うタイミングは近づいている。最後の消費日 (`anchor`) を起点にすれば、使わない日が続くほど予測日は相対的に近づき、`days_left` が減っていく。
2. **在庫は「未使用数」だから、使用中の 1 個が在庫に入っていない。** 本アプリは使い始めた時点で在庫から引く ([データモデル](01-domain-model.md))。在庫 3 ロールなら、いま使っている 1 ロールと合わせて実際には 4 回分ある。だから `uses_left + 1` 回分先を見る。
3. **知りたいのは「在庫が 0 になる日」ではなく「買っておくべき期限」。** 在庫 0 でも、次に使うのが半年後なら今すぐ買う必要はない。この式はそれを自然に表現する。

在庫 0 (`q = 0`) でペースが分かっている場合は `uses_left = 0` となり、`need_by_on = anchor + ceil(u / pace)` = 「最後に使った日から 1 回分の間隔が経った日」になる。くん煙剤を使い切った直後から半年間「購入推奨」が出続ける、という事態を防げる。ペースが分からず在庫 0 の場合は `urgent` (理由: `out_of_stock`) とする (7 節)。

## 6. 3 段階の閾値

| ステータス | 条件 | 既定値 | 根拠 |
|---|---|---|---|
| 購入推奨 `urgent` | `days_left <= urgent_days` | **7 日** | 週 1 回の買い物サイクル。次の買い物で必ず買う |
| そろそろ購入 `soon` | `days_left <= soon_days` | **21 日** | 3 週間。次かその次の買い物で買えばよい |
| 購入不要 `ok` | それ以外 | — | — |

品目ごとに `soon_threshold_days` / `urgent_threshold_days` で上書きできる。既定値は `config/tsumikura.yml` に置く。

## 7. 最低在庫数との合成

```ruby
RANK = { unknown: -1, ok: 0, soon: 1, urgent: 2 }.freeze

# 1. 最低在庫数による判定 (minimum が未設定なら nil)
by_minimum =
  unless minimum.nil?
    if    q <  minimum then :urgent
    elsif q == minimum then :soon
    else  :ok
    end
  end

# 2. 消費ペースによる判定 (pace が unknown なら nil)
by_pace =
  if pace.known?
    if    days_left <= thresholds.urgent_days then :urgent
    elsif days_left <= thresholds.soon_days   then :soon
    else  :ok
    end
  end

# 3. ペース不明で在庫 0 は購入推奨 (none モードを除く)
by_stockout = (mode != :none && !pace.known? && q <= 0) ? :urgent : nil

# 4. 悪い方を採用。すべて nil なら unknown
status = [ by_minimum, by_pace, by_stockout ].compact.max_by { RANK.fetch(_1) } || :unknown
```

- 最低在庫数の境界は **「下回ったら購入推奨、ちょうどならそろそろ購入」**。「最低在庫数 = この数は切らしたくない」という意味なので、ちょうどの時点ではまだ切らしていない。
- 「使用履歴が少なく予測できない間は最低在庫数のみで判定」という要件は、`by_pace` が `nil` になることで自然に満たされる。
- `by_stockout` は `none` モードには適用しない。`none` は「このアプリに予測させない」という意思表示なので、在庫 0 を知らせてほしい品目には最低在庫数 1 を設定する (`q = 0 < 1` で `urgent` になる)。
- `reason` は表示用に持つ: `:pace` / `:minimum` / `:out_of_stock` / `:no_data`。採用したステータスを出した判定のものを入れる。複数の判定が同じステータスなら `:out_of_stock` → `:minimum` → `:pace` の順で優先する。`unknown` のときは `:no_data`。
- `need_by_on` と `days_left` は、ペースが分かっていれば `reason` によらず `Result` に入れる (品目詳細に常に表示するため)。ペース不明なら `nil`。

## 8. 予測モード

`items.estimation_mode` は **auto / manual / none の 3 つだけ**とする。

| モード | 値 | 挙動 |
|---|---|---|
| `auto` | 0 | 既定。上記のとおり実績からペースを計算する |
| `manual` | 1 | `pace = 1 / manual_interval_days` (「1 単位を何日で使うか」を手入力)。窓内のイベント数や観測日数の条件は適用しない。`anchor` と `u` の求め方は `auto` と同じ (2 節) |
| `none` | 2 | ペース判定をしない (`unknown`)。**最低在庫数だけで判定する** (在庫 0 でも `by_stockout` は効かない)。非常用品などに使う |

`manual` は「実績はまだ無いが周期は分かっている」品目 (半年に 1 回のくん煙剤を買ったばかり、など) のための逃げ道である。実績が溜まれば `auto` に戻せばよい。

`manual_interval_days` は **UI (モデルのバリデーション) では必須**とする。「手動」を選んで空のままにすると予測が永久に `unknown` になり、`auto` より悪い状態に黙って落ちるためである。`Forecast::Pace` 側の「`nil` なら `unknown`」は、古いデータや直接 UPDATE に備えた防御として残す。

- 消費イベントが無い間の `anchor` は `tracking_started_on` (最初に在庫を登録した日) になる。`today` を起点にすると予測日が毎日後ろへ逃げ、いつまでも近づかないためである。
- 在庫イベントが 1 件も無い品目は `anchor` が `nil` なので `manual` でも `unknown` となり、在庫 0 なら `by_stockout` で `urgent` になる。

interval モードや「月あたりのペースを手入力する」モードは設けない。集計窓が自動で最大 730 日まで伸びるので、季節品も `auto` で扱えるためである。

## 9. エッジケース

| ケース | 挙動 |
|---|---|
| 在庫 0 でペース既知 | `need_by_on = anchor + ceil(u / pace)`。次に使う時期が遠ければ `ok` のまま |
| 在庫 0 でペース不明 (`auto` / `manual`) | `urgent` (`reason: :out_of_stock`) |
| 在庫 0 で `none` モード | 最低在庫数のみで判定。未設定なら `unknown` |
| 在庫が 1 回分に満たない (`0 < q < u`) | `uses_left = 0`。在庫 0 と同じく `need_by_on = anchor + ceil(u / pace)` |
| 消費イベントが 1 件のみ | ペース `unknown`。最低在庫数のみで判定 (未設定で在庫があれば `unknown`) |
| 消費イベントが 2 件のみで、古い方が窓の開始 | `event_count = 2` でペース既知。その 1 間隔 (新しい方の消費量 ÷ 2 件の間の日数) がペースになる |
| 同じ日に何度も記録した | その日は消費イベント 1 件。数量は合算される |
| 2 年以上使っていない | 窓の上限 730 日の外なので消費イベント 0 件 → `unknown`。最低在庫数のみで判定 |
| 使用間隔が 1 年を超える | 窓 730 日に消費イベントが 2 件入る時期と入らない時期があり、判定が安定しない。`manual` を使う |
| 観測日数が 14 日未満 | ペース `unknown`。UI は「データ収集中」 |
| 登録初日に大量使用 | `min_observed_days` が効くので、極端なペースは出ない |
| `need_by_on` が過去 | `today` に丸める (`days_left = 0` → `urgent`)。在庫が残っていても、想定より長く使っていない品目は `urgent` になる。実態に合わないときは棚卸で在庫を合わせるか、`manual` / `none` に切り替える |
| 在庫はあるが全ロットが期限切れ | `q = 0` として扱う。期限アラートとは別に要購入にも出る |
| 未来の日付の記録 | 作成できない (バリデーション) |
| アーカイブ済み品目 | 予測しない (一覧・ダッシュボード・買い物リストから除外) |

## 10. 検算例

### 例 1: トイレットペーパー (ふつうの日用品)

5 日に 1 ロールのペースで使い続けており、最後に使い始めたのは 2 日前。記録は 1 年以上ある。

| 入力 | 値 |
|---|---|
| 消費イベント | 2 日前、7 日前、12 日前、… (5 日おき) |
| 在庫 `q` | 3 ロール |
| `u` | 1 |
| `anchor` | 2 日前 (最後に使い始めた日) |

```
nth_event_on  = today - 22                 # 直近 5 件目
window_start  = min(today - 90, today - 22) = today - 90   # 消費イベント日で決まっていないので window_end = today
consumed      = 18                         # (today - 90, today] には 2, 7, ..., 87 日前の 18 件。92 日前は窓の外
observed_days = 90
pace          = 18 / 90 = 1/5

uses_left  = 3 / 1 = 3
need_by_on = (today - 2) + ceil((3 + 1) * 1 / (1/5)) = (today - 2) + 20 = today + 18
days_left  = 18   -> 21 日以内なので soon (そろそろ購入)
```

在庫 3 + 使用中の 1 = 4 回分 × 5 日 = 20 日分が、2 日前から始まっている。

### 例 2: くん煙剤 (年 2 回の季節品)

182 日おきに 1 個使っており、今日使って在庫が 0 になった。記録は 2 年分ある。

| 入力 | 値 |
|---|---|
| 消費イベント | 今日、182 日前、364 日前、546 日前、728 日前 |
| 在庫 `q` | 0 個 (使い切った) |
| `u` | 1 |
| `anchor` | 今日 (使用直後) |

```
nth_event_on  = today - 728                # 直近 5 件目
window_start  = max(min(today - 90, today - 728), today - 730) = today - 728
window_end    = anchor = today             # 窓の開始が消費イベント日なので anchor に揃える
consumed      = 4                          # (today - 728, today] の 4 件。728 日前のイベントは始点なので数えない
event_count   = 5                          # 始点を含む
observed_days = 728
pace          = 4 / 728 = 1/182

uses_left  = 0 / 1 = 0
need_by_on = today + ceil((0 + 1) * 1 / (1/182)) = today + 182
days_left  = 182  -> ok (購入不要)
```

在庫 0 でも「購入推奨」にならない。4 間隔 (728 日) で 4 個なので、ペースは実際の間隔どおり 1/182 になる。

その後、使わないまま日が進むと 5 件目のイベントが上限 730 日の外へ出て、窓は `(today - 730, today]` の 4 件 ÷ 730 日 = 1/182.5 になる。`need_by_on` は `anchor + 183` となり、`anchor` の 162 日後に `days_left = 21` で `soon`、176 日後に `days_left = 7` で `urgent` に変わる (厳密な 182 日間隔との差は 1 日)。

### 例 3: 単 3 電池 (1 回に複数個使う品目)

| 入力 | 値 |
|---|---|
| ペース | `pace = 1/10` 本/日 |
| 在庫 `q` | 5 本 |
| `u` | 2 (1 回の交換で 2 本使うことが多い) |
| `anchor` | 最後に交換した日 |

```
uses_left  = 5 / 2 = 2                # 整数除算。5 本ではあと 2 回しかまるごと交換できない
need_by_on = anchor + ceil((2 + 1) * 2 / (1/10)) = anchor + 60
```

端数の 1 本は「次の交換 1 回分」には足りないので数えない。`u` を使うことで、「本数は残っているのに交換できない」状態を予測日に反映できる。

## 11. PORO 構成

予測計算は ActiveRecord に依存させず、純粋関数として切り出す。

```
app/models/forecast/
  thresholds.rb        # Data.define(:soon_days, :urgent_days,
                       #             :window_min_days, :window_events, :window_max_days,
                       #             :min_samples, :min_observed_days)
  pace.rb              # Data.define(:per_day, :event_count, :observed_days, :source)
                       #   per_day: Rational (unknown のときは nil)
                       #   source: :auto / :manual / :unknown
  snapshot.rb          # Data.define(:quantity,           # q (期限切れロットを除く)
                       #             :minimum_quantity,   # minimum
                       #             :consumed,           # (window_start, today] の消費量
                       #             :event_count,        # [window_start, today] の消費イベント数
                       #             :observed_days,      # window_end - window_start
                       #             :anchor_on,          # 最後の消費イベント日 (無ければ tracking_started_on)
                       #             :unit_usage,         # u (中央値、既定 1)
                       #             :mode,               # :auto / :manual / :none
                       #             :manual_interval_days,
                       #             :thresholds,
                       #             :today)
  result.rb            # Data.define(:status, :pace, :need_by_on, :days_left, :reason)
  window.rb            # 窓の計算 (純粋関数):
                       #   Window.for(today:, nth_event_on:, last_event_on:, tracking_started_on:, thresholds:)
                       #   -> start_on / end_on / observed_days を持つ値オブジェクト
  calculator.rb        # AR 非依存の純粋関数: Snapshot -> Result
  snapshot_builder.rb  # AR クエリ担当: Item -> Snapshot (Window を使う)
  item_forecaster.rb   # Item -> Result (Builder + Calculator の合成 + リクエスト内メモ化)
  batch_forecaster.rb  # Item の Relation -> Hash{item_id => Result}
                       #   一覧画面用。集計を定数回のクエリでまとめて取る
```

`thresholds` / `pace` / `snapshot` / `result` / `window` / `calculator` の spec は DB を一切触らない (`rails_helper` ではなく `spec_helper` だけで動く)。ここが最も仕様が濃く、最も頻繁にテストする層なので、実行速度を最優先する。

- このため、これらのクラスは ActiveSupport の拡張 (`present?`、`Date.current`、`days.ago` など) にも依存させない。`today` は `Snapshot` から受け取り、日付の計算は `Date` の加減算だけで行う。
- 既定値の正は `config/tsumikura.yml` (13 節) である。`Forecast::Thresholds.default` は Rails を介さず、標準ライブラリの YAML でこのファイルの `shared.forecast` を読む (Rails を起動しない spec でも同じ値になる)。品目ごとの上書きは `SnapshotBuilder` が `Thresholds#with` で反映して `Snapshot` に詰める。

## 12. 期限判定 (予測とは独立)

残数が 1 以上のロットだけを対象に、ロットごとに判定する。

| ステータス | 条件 |
|---|---|
| `expired` | `lot.expires_on < today` |
| `expiring_soon` | `expired` ではなく、`lot.expires_on <= today + expiry_warning_days` (`item.expiry_warning_days`。未設定なら既定の 30) |
| `fresh` | それ以外 (期限 nil を含む) |

- 期限日の当日はまだ期限切れではない (`expires_on < today` で初めて `expired`)。
- 品目のステータスは、保有ロットの最悪値を採用する。
- `expired` のロットの残数は、要購入判定の `q` から除く (2 節)。
- 期限切れロットは品目詳細で強調表示し、そこから廃棄を記録できるようにする。

## 13. 設定ファイル

```yaml
# config/tsumikura.yml  (Rails.application.config_for(:tsumikura))
shared:
  forecast:
    window_min_days: 90     # 窓の最低の長さ。窓は (today - 90 日, today]
    window_events: 5        # 直近この件数目の消費イベント日まで窓を伸ばす
    window_max_days: 730    # 窓の最大の長さ。today - 730 日より前には伸ばさない
    soon_days: 21
    urgent_days: 7
    min_samples: 2          # [window_start, today] の消費イベントがこれ未満なら unknown
    min_observed_days: 14   # 観測日数がこれ未満なら unknown
  expiry:
    warning_days: 30
  notifications:
    digest_hour: 8          # 画面の文言用。実際の実行時刻は config/recurring.yml
```

品目ごとの上書きは `items.soon_threshold_days` / `urgent_threshold_days` / `expiry_warning_days` / `minimum_quantity` / `estimation_mode` / `manual_interval_days` で行う。

## 14. 将来の改善候補

- 生活パターンの変化への追随が遅いと感じたら、短期窓と長期窓を重み付けで合成する方式などに差し替える。`Forecast::Calculator` が PORO なので、spec を足すだけで検証できる。
