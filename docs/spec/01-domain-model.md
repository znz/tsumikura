# データモデル

[概要](00-overview.md) / [予測と要購入判定](02-forecast.md) / [画面](03-screens.md)

## 1. 設計判断

### 判断 1: 現在庫は「イベントの総和」を定義とし、ロット残数は再計算可能なキャッシュとする

```
lot.remaining_quantity  == lot.stock_movements.sum(:quantity)      … キャッシュ
item.current_quantity   == item.lots.sum(:remaining_quantity)      … キャッシュ
```

- **定義 (正)**: `stock_movements.quantity` の総和。
- **キャッシュ**: `lots.remaining_quantity` / `items.current_quantity`。一覧の N+1 と重い集計を避けるために持つ。
- **整合性の取り方**: 記録の作成・編集・削除は必ず同一トランザクション内で `item.lock!` してから `Stock::Recalculator.call(item)` を呼び、キャッシュを再計算する。イベント数は家庭用途では多くても年数千行なので、品目単位の全再計算で十分速い。
- **復旧手段**: `rake stock:verify` (差異検出) と `rake stock:recalculate` (全品目再計算) を用意する。キャッシュが壊れても台帳から必ず復元できる。
- **採用しない案**: (a) 差分更新のみ (`increment_counter`) — ズレたら直せない。(b) 完全イベントソーシング (キャッシュなし) — 一覧表示のたびに全品目の全移動を集計するのは遅く、Turbo の部分更新とも相性が悪い。

> **割り切り**: 残数は「符号付き数量の総和」なので **時系列上の途中在庫は再現しない**。過去日の使用記録を後から追加しても現在庫は正しく減るが、「その日の在庫」は分からない。直近の**確定済み**棚卸日より前の日付に記録を追加すると理屈上は矛盾するため、UI で「直近の棚卸日より前の日付です」と警告する (ブロックはしない)。警告は使用記録・購入・廃棄の**保存後の通知**に足す (JS 無しでも確実に出せる) ほか、フォームの日付欄にも直近の棚卸日を添える。判定は**品目単位** (`Item#last_counted_on`) で行う。棚卸は保管場所ごとなので、全体の最終棚卸日で見ると「冷蔵庫を数えただけ」で洗剤の購入にまで警告が出てしまい、誤警告が多いと読まれなくなる。下書きの棚卸と、実数を入れずにスキップした明細は数えない。

### 判断 2: 期限のない品目でもロットを作る (入庫 = ロットで統一)

- `lots.expires_on` を NULL 可にして、**すべての入庫がロットを作る**。
- 理由: FEFO 引き当て / 単価履歴 / 購入店履歴 / 残数計算が 1 本化される。「期限品だけ別経路」は分岐が増えてバグの温床になる。
- `lots.kind` で由来を区別する: `purchase` (通常購入) / `initial` (初期在庫投入) / `adjustment` (棚卸プラス差分・在庫不足時の自動補填)。
- 残数 0 のロットは `depleted_at` を打って一覧から畳む (物理削除しない)。

### 判断 3: 棚卸は「品目の合計だけ入力」を既定とし、ロット別入力は任意とする

- 既定 (すべての品目): 品目ごとに**実数の合計だけ**入力する。数え間違いの原因になるロット識別を家族に強いない。
  - 差分がマイナス → FEFO 順 (期限が近いロット → 購入が古いロット。期限切れロットは最後) に引く。
  - 差分がプラス → **`kind: adjustment` の新規ロット (期限 NULL、価格 NULL)** を作って足す。既存ロットに足すと「知らない期限」を勝手に主張することになるため。期限 NULL は FEFO で最後に引かれるので安全。
- 任意 (`tracks_expiry: true` かつロットが 2 件以上ある品目のみ): 「ロット別に数える」を展開すると、ロットごとに実数を入力できる。`stock_take_entries.lot_id` が埋まる。
  - **ロット別に入れた品目は、合計の入力を使わない** (より細かいほうを採る)。二重に数えないための規則で、画面にもその旨を出す。DB に両方あったときも、確定はロット別だけを反映する。
  - ロット別のマイナス差分は**そのロットからだけ**引く (FEFO で他のロットに回さない)。
  - **ロット別のプラス差分は、そのロットに正の `adjustment` を足す** (合計入力のときだけ新規の調整ロットを作る)。合計入力で新規ロットにするのは「知らない期限を主張しない」ためだが、ロット別入力ではユーザー自身がロットを特定しているのでその心配がない。逆に新規ロットを作ると、次の棚卸で同じ実物が「元のロット」と「期限なしの調整ロット」の 2 行に見え、数えるたびに水増し (または偽の消費イベント) が積み上がって収束しない。
- 棚卸は**ヘッダ + 明細**構成とする。保管場所を選んで一括で数え、最後にまとめて確定する (`finalized_at`)。下書き中は在庫に影響しない。
- 明細は**実数を入力した品目のぶんだけ**作る (画面を開いただけでは作らない)。「未入力」は**明細が無い**か `counted_quantity` が NULL かの 2 通りで表せるが、**アプリは NULL の行を作らない** (空で送り直された明細は削除する)。どちらも確定ではスキップする。
- 確定は `expected_quantity` を**確定時点の記録在庫で取り直してから**差分を出す。下書きを作ってから在庫が動いていても、差分は「今の記録在庫」との差になる。
  - 割り切り: 数えてから確定までに使用・購入があると、「数えた時点の実物」と「確定時点の記録在庫」の差を取ることになる (朝に実数 8 と数え、昼に 1 使い、夜に確定すると記録 9 → 実数 8 で差分 −1。実物は 7 なので 1 ずれる)。時系列上の途中在庫を再現しない割り切り (判断 1) の帰結で、**確認画面は確定で適用される差分 (今の記録在庫との差) を出し、数えたあとに在庫が動いた明細には「数え直してください」と添える**。
- 1 件も数えていない棚卸は確定できない。在庫は動かないのに棚卸日だけが進み、以降の記録すべてに「直近の棚卸日より前です」の警告が出てしまうため。

### 判断 4: 用途は品目に紐づく子レコード (`item_purposes`) とする

- `item_purposes` は `belongs_to :item`。グローバルな用途マスタにはしない (「リモコン」は単 3 電池の文脈でのみ意味を持つ)。
- `usage_records.item_purpose_id` は NULL 可 (用途を使わない品目)。
- 購入予測は品目全体の消費ペースで行い、用途は**履歴と交換周期の表示専用**とする。
- 交換周期は同一用途の `used_on` の差分の**中央値** (平均より外れ値に強い)。件数 1 なら「前回 2025/01/15 (8 か月前)」とだけ表示する。

### 判断 5: 買い物リストは「導出 + 差分の永続化」とする

- 一覧表示 = 「要購入判定が `soon` / `urgent` の品目 (導出)」 ∪ 「`shopping_list_items` の手動行」。
- `shopping_list_items` に永続化するのは**ユーザーが手を加えたものだけ**。手動追加、数量の上書き、チェック済み、スヌーズ (今回は買わない)。
- 自動行を毎回テーブルに書き戻す方式は採らない (GET に副作用が出る / 判定変化との同期がややこしい)。チェック操作が来た時に初めて `find_or_create_by(item:)` する。
- 買い物中にチェック → 「購入として記録」画面へ遷移し、チェック済み行から `lots` をまとめて作る。

**Phase 11 で決めた規則** (実装: `app/models/shopping_lists/`)

- 一覧の組み立ては `ShoppingLists::Builder` (読み込み) + `ShoppingLists::Merger` (DB に触らない純粋関数) に分ける。表示単位は `ShoppingLists::Row` (値オブジェクト)。
- **`added_manually` 列を追加した**。手動追加は「チェックも数量の上書きも無い行」と見分けが付かず、列が無いと「購入不要の品目を手で足した行」が即座に消えてしまうため。
- **一覧に出す行**: 判定が `urgent` / `soon`、または `checked_at` がある、または `added_manually`、または自由入力。**数量の上書きだけが残った行は出さない** (買い終えた品目の上書きが居座らないように)。アーカイブ済みの品目は永続行があっても出さない。
- **並び順**: `urgent` → `soon` → 手動 (品目) → 自由入力。同じ組の中は `days_left` の小さい順 (`nil` は最後)、同値はよみ順。
- **推奨数量**: `minimum_quantity` があれば不足分 (`minimum_quantity - q + 1`、最低在庫数を 1 つ上回るまで) を求め、`default_pack_size` があれば**入数の倍数に切り上げる** (最低 10・在庫 0・入数 4 なら 12)。`minimum_quantity` が無ければ、`default_pack_size` があれば 1 パック、無ければ 1。1 未満と `Item::MAX_QUANTITY` 超にはならない。`q` は `Forecast::Result#quantity` (期限切れを除いた在庫)。手で入れた `quantity` があればそちらが優先。
- **スヌーズ**: `ShoppingListItem::SNOOZE_DAYS` (7) 日先を `snoozed_until` に入れる。`snoozed_until >= today` の間は自動セクションに並べず、「スヌーズ中 n 件」として畳んで見せる (当日はまだ見送り、翌日から戻る)。期限が過ぎた行は**消さずに無視**する (GET に副作用を出さない)。チェック済みならスヌーズ中でも一覧に残す。
- **行の掃除**: (1) 操作の結果何の意図も残らなくなった行 (チェックを外しただけの行) はその場で消す。条件は `ShoppingListItem.blank_for_items(today)` に置き、**条件付きの DELETE** で消す (メモリ上の値で判断して destroy すると、読んだあとに他の人が付けたチェックごと消してしまう)。(2) **購入を記録したら `ShoppingListItem.settle_after_purchase!(item)`** でその品目の行を片づける (チェックも数量の上書きも手動追加の印もスヌーズも「買う前の意思表示」なので、買った時点で役目を終える)。単品の購入 (`LotsController#create`) とまとめ購入の両方で呼ぶ。**これが無いと、数量の上書きだけが残った行が永遠に残り、数か月後にまた urgent に戻ったときに古い上書きが復活する**。(3) まとめ購入の成功時に `ShoppingListItem.purge_stale!` で見えない行 (アーカイブ済み品目の行・期限切れのスヌーズ) も片づける。(4) それでも残る行 (買い物をしないまま日が経った場合) は Phase 12 の日次ジョブに申し送る。
- **自由入力**: 品目を持たないので在庫には反映できない。まとめ購入の画面で「在庫には記録されません」と明示したうえで、記録の成功時にチェック済みの自由入力行も一緒に消す (「買った」ものとして扱う)。ただし**消すのはフォームに出ていた行だけ** (`purchase[free_text_ids][]` で id を持ち回る)。開いている間に家族がチェックした行まで消すと、見ていないものが黙って消える。
- **行の DOM id** (`ShoppingLists::Row#dom_id`) は品目の行なら `shopping_list_row_item_<item_id>`、自由入力なら `shopping_list_row_entry_<id>`。**永続行の有無で変えない** (チェックのたびに id が変わると、リダイレクト先のアンカーも Turbo の morph の対応付けも外れてスクロール位置が飛ぶ)。
- **行の作成が競合したとき** (部分一意 index の `RecordNotUnique` / uniqueness の検証エラー) は、1 度だけやり直して相手が作った行に同じ操作を適用する (負けた側の操作を黙って捨てない)。

### 判断 6: 店舗マスタを持ち、価格はロット単位の税込合計とする

- `stores` マスタ (name, note)。`lots.store_id` は NULL 可。
- 価格は `lots.price_yen` (integer, **税込合計金額**)。レシートを見て入力するのが自然なため。
- **単価は導出** (`price_yen / initial_quantity`)。品目詳細に「最近の単価: 平均 38 円/本」を表示する。
  - 単価の平均は `price_yen IS NOT NULL` のロットのみで計算する (調整ロットの価格 NULL で平均が歪まないように)。
  - 「最近」は**購入日の新しい順に 5 件** (`Lot::RECENT_PRICED_LOTS`)。何年も前の単価に引きずられないようにする。
  - 平均は**その 5 件の総額 ÷ 総数量** (単価の単純平均ではない)。
  - 端数は四捨五入して円単位。ただし**単価が 10 円未満のときだけ小数 1 桁**で出す (100 枚 30 円 → 0.3 円/枚。四捨五入すると 0 円に潰れるため)。
- 通貨は JPY 固定 (`currency` カラムは持たない)。円は最小単位が 1 なので integer で十分。
- 税抜入力は用意しない (「税込で入力」とプレースホルダで明示する)。

## 2. テーブル定義

### 認証・ユーザー

```
users
  id                bigint pk
  email_address     string   not null, unique index  # Rails 標準の normalizes で小文字化。ログイン ID
  password_digest   string   not null
  name              string   not null                # 表示名「おかあさん」など
  role              integer  not null default 0      # 0: member, 1: admin
  webauthn_id       string   unique                  # パスキー初回登録時に生成
  notify_purchases  boolean  not null default true
  notify_expiries   boolean  not null default true
  deactivated_at    datetime                         # 無効化 (削除はしない: 記録者参照が残るため)
  timestamps

sessions              # bin/rails generate authentication が生成
  id, user_id (fk not null), ip_address string, user_agent string, timestamps

passkeys
  id, user_id (fk not null)
  external_id   string not null unique     # Base64URL credential ID
  public_key    text   not null            # Base64 COSE key
  sign_count    bigint not null default 0
  nickname      string not null            # 「太郎のiPhone」
  last_used_at  datetime
  timestamps

web_push_subscriptions
  id, user_id (fk not null, on_delete: restrict)
  endpoint          string not null unique  # 通常 200-500 バイト。string(2048) + unique index
                                            # check: endpoint LIKE 'https://%'
                                            # モデルは ASCII + 既知の Push サービスのホスト (443) に絞る
  p256dh_key        string not null         # string(255)。デコードして 65 バイト・先頭 0x04
  auth_key          string not null         # string(255)。デコードして 16 バイト
  user_agent        string                  # string(255)。長い値は切り詰めて保存する
  last_delivered_at datetime
  failure_count     integer not null default 0
  timestamps
  # endpoint は端末 + ブラウザに 1 つ。同じ端末で別の家族がログインしたら user_id を付け替える
  # (行は増やさない)。1 ユーザー 20 件まで (超えたら古い方から消す)。
  # ユーザーの無効化では購読を消さない (無効化は取り消せるため。配信側が User.active で落とす)。
  # docs/spec/04-notifications.md 3 節
```

### マスタ

```
categories
  id, name string not null unique, position integer not null default 0, timestamps

storage_locations
  id, name string not null unique, position integer not null default 0, timestamps

stores
  id, name string not null unique, note text, timestamps
```

- `categories` / `storage_locations` の `position` には index を張る (一覧は常に `position` 順で引くため)。
- `position` は **1 始まり**。作成時に `max(position) + 1` を振り、並べ替え (「上へ / 下へ」) のたびに
  1 から振り直す。重複や欠番があっても並びが壊れない代わりに、並べ替えはマスタ全行を UPDATE する
  (家庭で使う件数なので十分)。並べ替えで `updated_at` は更新しない。
- `stores` は `position` を持たないので名前順に並べる。
- 名前の前後の空白は保存時に落とす。`String#strip` は全角スペース (U+3000) を落とさず
  「洗面所」と「洗面所　」が別名として一意制約をすり抜けるため、`[[:space:]]` で落とす。

### 品目

```
items
  id
  name                   string  not null
  name_reading           string                        # ひらがな検索用 (任意)
  category_id            fk null (categories)
  storage_location_id    fk null (storage_locations)
  unit                   string  not null default "個" # ロール/本/個/袋/パック
  default_pack_size      integer                       # 入数の既定値 (例: 12ロール)
  minimum_quantity       integer                       # 最低在庫数 (任意)
  tracks_expiry          boolean not null default false
  tracks_purposes        boolean not null default false
  estimation_mode        integer not null default 0    # 0:auto 1:manual 2:none
  manual_interval_days   integer                       # estimation_mode=manual: 1 単位を何日で使うか
  soon_threshold_days    integer                       # null = 既定 21
  urgent_threshold_days  integer                       # null = 既定 7
  expiry_warning_days    integer                       # null = 既定 30
  favorite               boolean not null default false # クイック記録に固定表示
  archived_at            datetime
  note                   text
  current_quantity       integer not null default 0    # キャッシュ: 全ロットの残数合計
  tracking_started_on    date                          # キャッシュ: 最も古い stock_movement の occurred_on
  last_consumed_on       date                          # キャッシュ: 最後の消費イベント日 (= 予測のアンカー)
  timestamps
  index: [category_id], [storage_location_id], [archived_at], [favorite], [name]
  check: current_quantity >= 0

item_purposes
  id, item_id (fk not null)
  name             string  not null
  default_quantity integer not null default 1     # 「リモコンは2本」
  position         integer not null default 0
  archived_at      datetime
  timestamps
  index: [item_id, name] unique, [item_id, position]
  check: default_quantity > 0
```

- **モデル側のバリデーション** (DB の制約ではない):
  - 長さ: マスタの `name` と `items.name` は 50 文字、`items.name_reading` は 100 文字、`items.unit` は 20 文字まで。
  - 整数の上限: 数量系 (`default_pack_size` / `minimum_quantity`) は `Item::MAX_QUANTITY` (99,999)、
    日数系 (`manual_interval_days` / `soon_threshold_days` / `urgent_threshold_days` / `expiry_warning_days`) は
    `Item::MAX_DAYS` (3,650) まで。**上限が無いと 4 バイト整数をはみ出した入力が書き込み時に
    `ActiveModel::RangeError` になり、検証エラー (422) ではなく 500 になる**ため必ず付ける。
  - `urgent_threshold_days <= soon_threshold_days` (どちらも既定値と合成した実効値で比べる)。
  - `category_id` / `storage_location_id` が入っていて参照先が無ければ検証エラーにする
    (フォームを開いている間にマスタが削除されると、そのままでは外部キー違反で 500 になる)。
- `name_reading` は**カタカナをひらがなにそろえて保存**する (`tr("ァ-ヶ", "ぁ-ゖ")`)。検索語にも同じ変換を
  掛けるので、「トイレ」でも「といれっとぺーぱー」に当たる。空白だけの入力は NULL にする。
- 一覧の既定の並び順は `COALESCE(name_reading, name)` (漢字の名前をコードポイント順に並べても五十音順にならないため)。
- `estimation_mode` は **auto / manual / none の 3 つだけ**とする。interval モードは設けない ([予測](02-forecast.md) の集計窓が自動で伸びるため不要)。
- `manual_interval_days` は「1 単位を何日で使うか」。`pace = 1 ÷ manual_interval_days` となる。
  `estimation_mode: manual` のときは**モデルで必須**にする (空のままだと予測が永久に `unknown` になり、
  `auto` より悪い状態に黙って落ちるため)。
- `item_purposes` の `position` は**品目ごとに 1 から**振る (`Positioned` を品目の中だけで使う)。
  全体で連番にすると、別の品目に用途を足しただけで並び順が変わる。
- `item_purposes.name` は品目の中で一意 (大文字小文字を無視)。長さは 50 文字まで。
- `last_consumed_on` は使用記録だけでなく**棚卸のマイナス差分も含む**最新日 (廃棄は含まない)。ダッシュボードの「最近使った品目」の並び順にも使う。
- 集計窓の下限に使うため `tracking_started_on` (その品目の最初の在庫イベント日 = 全 `stock_movements` の `occurred_on` の最小値) を持つ。在庫イベントが無ければ NULL。
- どちらも `Stock::Recalculator` が台帳から再計算するキャッシュである。過去日の記録を足したり消したりしても正しい値に戻る。

### 在庫台帳

```
lots                                  # 1 行 = 1 回の入庫
  id
  item_id            fk not null
  kind               integer not null default 0   # 0:purchase 1:initial 2:adjustment
  acquired_on        date    not null             # 購入日 / 初期在庫日 / 棚卸日
  expires_on         date                         # 任意 (期限なしは null)
  initial_quantity   integer not null             # 入庫時の数量 (> 0)
  remaining_quantity integer not null default 0   # キャッシュ
  pack_size          integer                      # 入数 (入力の記録用)
  pack_count         integer                      # パック数
  price_yen          integer                      # 税込合計 (任意)
  store_id           fk null (stores)
  user_id            fk not null (users)          # 記録者
  note               text
  depleted_at        datetime                     # 残 0 になった日時
  timestamps
  index: [item_id, expires_on], [item_id, depleted_at], [expires_on], [store_id]
  check: initial_quantity > 0
  check: remaining_quantity >= 0

stock_movements                       # 在庫の唯一の真実
  id
  item_id             fk not null      # 非正規化 (lot 経由でも辿れるが集計用に必須)
  lot_id              fk not null
  kind                integer not null # 0:purchase (initial ロットの入庫も含む) 1:usage 2:adjustment 3:disposal
  quantity            integer not null # 符号付き。purchase/正の adjustment は正、usage/disposal/負の adjustment は負
  occurred_on         date    not null
  usage_record_id     fk null
  stock_take_entry_id fk null
  disposal_reason     integer          # kind=disposal のみ: 0:expired 1:damaged 2:lost 3:other
  user_id             fk not null
  note                text
  timestamps
  index: [item_id, occurred_on], [lot_id], [usage_record_id],
         [stock_take_entry_id], [kind, occurred_on]
  check: quantity <> 0

usage_records                         # ユーザーの「使った」操作 1 回 (複数 movement に分割されうる)
  id
  item_id         fk not null
  item_purpose_id fk null
  quantity        integer not null     # > 0
  used_on         date    not null
  user_id         fk not null
  note            text
  timestamps
  index: [item_id, used_on], [item_purpose_id, used_on], [used_on]
  check: quantity > 0

stock_takes                           # 棚卸ヘッダ
  id
  counted_on          date not null
  storage_location_id fk null          # null = 全体 (マスタの削除は nullify)
  user_id             fk not null
  note                text
  finalized_at        datetime         # null = 下書き (在庫に未反映)
  timestamps
  index: [counted_on], [finalized_at], [storage_location_id, counted_on]

stock_take_entries                    # 棚卸明細
  id
  stock_take_id     fk not null
  item_id           fk not null
  lot_id            fk null            # ロット別に数えた場合のみ
  expected_quantity integer not null default 0   # 確定時点の記録在庫
  counted_quantity  integer            # 実数 (>= 0)。NULL = 未入力 (確定でスキップ)
  difference        integer            # counted - expected (未入力なら NULL)
  timestamps
  index: [stock_take_id, item_id, lot_id] unique where lot_id is not null
  index: [stock_take_id, item_id]      unique where lot_id is null
  index: [id, item_id] unique          # stock_movements の複合外部キーの参照先
  check: expected_quantity >= 0
  check: counted_quantity IS NULL OR counted_quantity >= 0
  check: (counted_quantity IS NULL AND difference IS NULL)
      OR (counted_quantity IS NOT NULL AND difference = counted_quantity - expected_quantity)
```

- `counted_quantity` / `difference` を NULL 可にしたのは、**未入力をそのまま表せるようにする**ため
  (画面の「未入力はスキップ」と 1 対 1 になる)。`difference` は従属値なので、
  `counted - expected` との食い違いを DB の check 制約でも止める (二重管理のずれ)。
- 一意 index を 2 本に分けたのは、PostgreSQL の UNIQUE が NULL 同士を別物として扱うため
  (合計行を 1 行に保てない)。`NULLS NOT DISTINCT` は PostgreSQL 15 以降なので使わない。
- `stock_take_entries.lot_id` の外部キーは **複合** `(lot_id, item_id) → lots(id, item_id)`
  (`stock_movements` と同じ理由で「他の品目のロットは数えられない」ことを DB で守る)。

### 買い物リストと通知状態

```
shopping_list_items                   # 手動追加 / 上書き / チェック状態のみ永続化
  id
  item_id       fk null (items)        # null = マスタにない自由入力
  free_text     string                 # item_id が null のとき必須
  quantity      integer                # 手入力の希望数 (null = 推奨数量を使う)
  checked_at    datetime
  snoozed_until date                   # 「今回は買わない」(この日まで並べない)
  added_manually boolean not null default false   # 手で足した行の目印 (判定が ok に戻っても消さない)
                                       #   購入を記録したら行ごと消える (settle_after_purchase!)
  added_by_id   fk not null (users)
  timestamps
  index: [item_id] unique where item_id is not null
  index: [checked_at]
  check: (item_id is not null) or (free_text is not null)
  品目の fk は on_delete: restrict (品目は物理削除しない)。added_by も restrict

item_alert_states                     # Web Push の重複通知防止
  id
  item_id                  fk not null unique
  notified_purchase_status string      # 前回突き合わせた要購入ステータス ("urgent" など)
  notified_expiry_status   string      # 前回突き合わせた期限ステータス ("expired" など)
  notified_at              datetime    # 最後に突き合わせた時刻 (送らなかった日も更新する)
  timestamps
```

- ステータスの 2 列は **integer ではなく string** にした。判定の `status` は Symbol で、enum の
  整数に写すとどちらの順位表 (要購入 / 期限) の何番かが DB からは読めなくなる。文字列なら
  `ja.forecast.status` / `ja.expiry.status` のキーとそのまま一致し、`Forecast::Calculator::RANK` /
  `Expiry::Status::RANK` で比べられる ([予測](02-forecast.md) 14 節 / [通知](04-notifications.md) 4 節)。
- `item_id` の外部キーは `on_delete: :restrict`。アーカイブ済みの品目の行は日次ジョブが消す。

日付の列 (`lots.acquired_on` / `stock_movements.occurred_on` / `usage_records.used_on` / `stock_takes.counted_on`) には**未来の日付を指定できない** (モデルのバリデーション)。過去日は自由に指定できる。消費イベントが必ず今日以前にあることを、[予測](02-forecast.md) が前提にしている。

- `stock_movements.usage_record_id` / `stock_take_entry_id` は、参照先のテーブルを作るフェーズ (使用記録 / 棚卸) で `add_foreign_key` する。列と index は在庫台帳と同時に作っておく。
  - `stock_take_entry_id` の外部キーも **複合** `(stock_take_entry_id, item_id) →
    stock_take_entries(id, item_id)` で、`on_delete` は付けない (`usage_record_id` と同じ理由)。
  - `usage_record_id` の外部キーに **`on_delete` は付けない** (既定の NO ACTION)。使用記録の削除は必ず
    `Stock::DeleteMovement` が movement を先に消してキャッシュを再計算するので、DB 側で黙って cascade
    させると台帳だけが消えてキャッシュがずれる。`dependent: :destroy` を通らない削除は DB が止める。
  - `usage_record_id` の外部キーは **複合** `(usage_record_id, item_id) → usage_records(id, item_id)`
    (`usage_records` に `[id, item_id]` の unique index を張る)。`(lot_id, item_id)` と同じ理由で、
    非正規化した `item_id` が使用記録とずれると別の品目のキャッシュが古いまま残る。
  - `usage_records.item_purpose_id` の外部キーは **複合** `(item_purpose_id, item_id) →
    item_purposes(id, item_id)` で `on_delete: :restrict`。用途を消すと、その用途の交換履歴と
    交換周期まで失われるため restrict にし、同時に「他の品目の用途は指せない」ことも DB で保証する。
    モデル側でも「使用記録がある用途は削除できない」で止め、アーカイブに誘導する。
  - どちらも MATCH SIMPLE なので、`usage_record_id` / `item_purpose_id` が NULL の行は対象外になる
    (用途なしの使用記録や、購入・棚卸の movement はそのまま通る)。
- `stock_movements.item_id` は**複合外部キー** `(lot_id, item_id) → lots(id, item_id)` で守る (`lots` に `[id, item_id]` の unique index を張る)。ロットとずれた `item_id` の行は、品目単位の再計算 (`where(item_id:).group(:lot_id)`) からも検査からも黙って落ちるので、モデルの検証だけに頼らない。
- **DB の check 制約**:
  - `lots`: `initial_quantity > 0` / `remaining_quantity >= 0` / `(pack_size IS NULL) = (pack_count IS NULL)` / `pack_size IS NULL OR pack_size * pack_count = initial_quantity` (入数 × パック数は「両方あって積が数量と一致する」か「両方 NULL」)。
  - `stock_movements`: `quantity <> 0` / `(kind = 0 AND quantity > 0) OR (kind IN (1,3) AND quantity < 0) OR kind = 2` (符号と種別の対応) / `(kind = 3) = (disposal_reason IS NOT NULL)` (**廃棄には必ず理由があり、廃棄以外には理由が無い**。理由の無い廃棄は「なんとなく減った」を廃棄で片づけた記録になり、あとから何が起きたのか分からなくなる)。
- `lots.user_id` / `stock_movements.user_id` の外部キーは `restrict`。ユーザーは物理削除しない方針なので、記録者が消えないことを DB 側でも保証する。
- **モデル側のバリデーション** (DB の制約ではない):
  - 整数の上限: `lots.initial_quantity` / `pack_size` と `stock_movements.quantity` の絶対値は `Lot::MAX_QUANTITY` (= `Item::MAX_QUANTITY` 99,999)、`pack_count` は `Lot::MAX_PACK_COUNT` (999)、`price_yen` は `Lot::MAX_PRICE_YEN` (9,999,999) まで。**上限が無いと 4 バイト整数をはみ出した入力が `ActiveModel::RangeError` になり 422 ではなく 500 になる**ため必ず付ける (入数 × パック数の積も同じ検証に掛ける)。
  - `stock_movements.quantity` の符号は `kind` と対応させる (`purchase` は正、`usage` / `disposal` は負、`adjustment` は両方あり)。符号の取り違えは在庫が逆に動くので、モデルで固定する。
  - `stock_movements.item_id` は `lot.item_id` と一致していなければならない (集計用の非正規化がずれると在庫の合計が壊れる)。
  - `lots.store_id` が入っていて参照先が無ければ検証エラーにする (フォームを開いている間に店舗が削除されると、そのままでは外部キー違反で 500 になる)。

> `item_alert_states` を `items` のカラムにしない理由: 日次ジョブが `items` を毎日 UPDATE すると `updated_at` が汚れ、「最近編集した品目」などの表示が使えなくなるため。テーブル 1 枚のコストは小さい。

## 3. 削除と参照整合性のルール

| 対象 | ルール |
|---|---|
| 品目 | 物理削除しない。`archived_at` でアーカイブし、一覧・ダッシュボード・買い物リストから外す。履歴と集計には残す |
| ロット | **出庫の `stock_movement` (負の数量) が紐づくロットは削除できない** (バリデーションエラー)。使用・廃棄だけでなく**棚卸のマイナス差分 (負の `adjustment`) も対象**にする (消すと確定済みの棚卸の記録と消費ペースの分子まで消えるため)。**確定済みの棚卸でロット別に数えたロットも削除できない** (差分 0 やプラス差分の明細には負の movement が付かないので、出庫のガードだけでは止まらない)。入庫の記録だけのロットは削除可。削除するとその `purchase` movement と、下書きの棚卸明細も消え、在庫が元に戻る。画面から編集・削除できるのは `kind` が `purchase` / `initial` のロットだけ (調整ロットは、元になった棚卸・使用記録の側から直す) |
| 廃棄 | 削除可 (取り消し)。`kind: disposal` の `stock_movement` 1 行が記録そのものなので、その行を消して `Stock::Recalculator` で在庫が戻る。数量がロットをまたいだ廃棄は行が分かれるので、1 行ずつ取り消す |
| ロットの数量編集 | 編集後の残数が負になる変更は**バリデーションエラー**にする (「このロットからは既に 5 本使われています」) |
| 使用記録 | 削除可。分割された `stock_movements` も `dependent: :destroy` で消え、`Stock::Recalculator` で在庫が戻る。在庫不足を補填した調整ロットも、movement が無くなれば一緒に消す |
| 用途 | **使用記録が紐づく用途は削除できない** (バリデーションエラー)。消すと交換履歴と交換周期が失われるため、`archived_at` でアーカイブして一覧から外す。外部キーも `restrict`。使用記録が無い用途 (打ち間違いなど) は削除できる |
| 棚卸 | 下書きは削除可。確定済みは削除しない (調整 movement の履歴が残る)。確定済みかどうかの判定は**ヘッダを `lock!` したあと**に行う (確定と削除が同時に走ると、確定済みの棚卸が消えてしまう)。確定済みの明細は足す・直す・消すのいずれもできない (`StockTakeEntry::Finalized`)。ただし品目ごと消すときは明細も一緒に消す |
| ユーザー | 削除しない。`deactivated_at` で無効化する (記録者参照が残るため) |
| カテゴリ / 保管場所 / 店舗 | **削除時は nullify**。外部キーは `on_delete: :nullify`、モデルは `dependent: :nullify`。削除前に「n 件の品目からカテゴリが外れます」と確認する。**保管場所を消すと、その場所の下書きの棚卸は「すべての保管場所」を対象にした棚卸に変わる** (数える品目が全品目に広がる)。確定済みの棚卸は明細がそのまま残るので影響を受けない |

## 4. 主要な関連

```ruby
class Item < ApplicationRecord
  belongs_to :category, optional: true
  belongs_to :storage_location, optional: true

  # prefix は必須。付けないと none が AR の Item.none (空スコープ) と衝突し、
  # Rails がクラスロード時に ArgumentError を出す。
  # 予測に渡すときは estimation_mode.to_sym にする (Forecast::Pace は文字列を受け付けない)
  enum :estimation_mode, { auto: 0, manual: 1, none: 2 }, prefix: true, validate: true

  # 宣言の順がそのまま削除の順になるので、参照する側から先に消す
  # (movement → ロット、使用記録 → 用途)
  has_many :stock_movements, dependent: :destroy
  has_many :lots, dependent: :destroy
  has_many :usage_records, dependent: :destroy
  has_many :item_purposes, -> { order(:position, :id) }, dependent: :destroy
  has_one  :alert_state, class_name: "ItemAlertState", dependent: :destroy
  has_one  :shopping_list_item, dependent: :destroy

  scope :active, -> { where(archived_at: nil) }
end

class Category < ApplicationRecord
  has_many :items, dependent: :nullify
end

class Lot < ApplicationRecord
  belongs_to :item
  belongs_to :store, optional: true
  belongs_to :user
  has_many   :stock_movements, dependent: :destroy

  # FEFO: 期限が近い順 → 古い購入順。期限 nil はその後、期限切れロットは最後
  scope :fefo, ->(today = Date.current) {
    order(Arel.sql(sanitize_sql_array([ "(expires_on < ?) IS TRUE", today ])),
          Arel.sql("expires_on ASC NULLS LAST"), :acquired_on, :id)
  }
  scope :available, -> { where("remaining_quantity > 0") }
  scope :expired,   ->(today = Date.current) { where(expires_on: ...today) }
end

class UsageRecord < ApplicationRecord
  belongs_to :item
  belongs_to :item_purpose, optional: true
  belongs_to :user
  has_many   :stock_movements, dependent: :destroy   # 1..n (FEFO で分割)

  # 引き当て先のロットの手動指定 (期限を管理する品目のみ)。既定は FEFO の自動引き当てなので
  # DB には持たず、引き当ての結果は stock_movements に残る
  attr_accessor :lot_id
  # 在庫不足を補填した数 (フラッシュの「n 個を調整しました」用)。DB には持たない
  attr_accessor :compensated_quantity
end
```

`Item` の `has_many` は**宣言の順がそのまま削除の順になる**ので、参照する側から先に消す
(`stock_movements` → `lots`、`usage_records` → `item_purposes`)。逆にすると
`Lot#ensure_not_consumed` / `ItemPurpose#ensure_not_used` と外部キーに止められる。

`UsageRecord#quantity` は**空で送られたら補う** (選んだ用途の `default_quantity`、用途なしなら 1)。
「リモコンは 2 本」を JS 無しでも効かせるための規則で、0 や負は入力の誤りとして検証エラーにする。

## 5. コマンド (サービスオブジェクト)

すべて `ApplicationRecord.transaction` + `item.lock!` の中で動かす。

```
app/models/stock/
  allocator.rb            # FEFO 引き当て: (item, quantity) -> [[lot, qty], ...]
  recalculator.rb         # lot.remaining_quantity / lot.depleted_at / item.current_quantity /
                          #   tracking_started_on / last_consumed_on を再計算
  verifier.rb             # キャッシュと台帳の差異を集める (rake stock:verify)
  usage_movements.rb      # 使用記録 1 件ぶんの movement の作成と片づけ (下の 3 つが共有する)
  record_usage.rb         # UsageRecord + StockMovement(s) を作る
  record_purchase.rb      # Lot + StockMovement(purchase) を作る (kind: initial も同じ経路)
  record_bulk_purchase.rb # まとめ購入: チェック済み行を 1 トランザクションで記録 (record_purchase.call! を入れ子で)
  revise_lot.rb           # ロットの編集 (入庫の movement を直して再計算)
  delete_lot.rb           # ロットの削除 -> 再計算
  record_disposal.rb      # StockMovement(disposal) を作る (Disposal フォームオブジェクトを返す)
  delete_disposal.rb      # 廃棄の取り消し (movement 1 行を消して再計算)
  finalize_stock_take.rb  # StockTake 確定 -> 差分から StockMovement(adjustment) を作る
  write_stock_take_entries.rb  # 棚卸の下書きに実数を書き込む (在庫には触らない)
  revise_usage.rb         # 使用記録の編集 (movements を作り直して再計算)
  delete_movement.rb      # 使用記録の削除 -> 再計算 (廃棄は delete_disposal.rb)
```

廃棄は `stock_movements` 1 行が記録そのものでヘッダを持たないので、入力の検証は
`app/models/disposal.rb` (`ActiveModel` のフォームオブジェクト) が受け持つ。
削除も `Stock::DeleteMovement` に引数の型で分岐させず `Stock::DeleteDisposal` に分ける。

サービスは「保存できたか」を戻り値のレコード (`persisted?` / `errors`) で伝え、例外は使わない。
検証エラーのときは `ActiveRecord::Rollback` でトランザクションを畳み、**Lot だけ・movement だけが残る
状態を作らない**。ただし**台帳の異常は例外にする**: ロックの後に読み直した対象が既に消えていれば
`ActiveRecord::RecordNotFound`、入庫の movement が無いロットは `InboundMovementMissing`。
「削除しました」と嘘をつかないための区別で、コントローラ側で拾って案内する。

**サービスを書くときの決まり**

- **ロックの後に読み直す**。`item.lock!` の前に読んだレコード (ロット・ロット一覧) はロック待ちの間に
  古くなっている。`lock!` の直後に `reload` してから判断・更新する。Phase 8 の `Stock::Allocator` も
  引き当て対象の `lots.available.fefo` をロックの後に読むこと。
- **入れ子で呼ぶサービスには `call!` を用意する**。内側の `raise ActiveRecord::Rollback` は内側の
  `transaction` に握りつぶされ、外側はそのままコミットされてしまう。入れ子で使うときは例外
  (`ActiveRecord::RecordInvalid`) を上げる `call!` を呼ぶ。
- **複数の品目をロックするときは id の昇順**でロックする (デッドロック防止)。
- 台帳が壊れている状態 (入庫の movement が無いロットなど) は黙って直さず例外にして気づけるようにする。
- 予測 (Phase 10) の消費の定義は `StockMovement.consumption` スコープを使い回す。

**引き当て順 (`Stock::Allocator`)**

```ruby
Stock::Allocator.call(item:, quantity:, user:, on:, preferred_lot_id: nil, fallback_lot_ids: [],
                      compensate: true, expired_first: false)
  # => Result(allocations: [[lot, qty], ...], shortage:, compensating_lot:,
  #           preferred_lot_unavailable:)
```

自動引き当ては FEFO (期限が近い順 → 購入が古い順、期限なしはその後) で行い、**期限切れロットは最後**に回す。要購入判定の在庫 `q` は期限切れロットを除いて数えるので、期限切れロットから先に引くと「使ったのに `q` が減らない」状態になるためである。期限切れのものを実際に使った場合は、使用記録のロット選択で手動指定する。

- `preferred_lot_id`: ユーザーが選んだロット。FEFO より先に引く。
- `fallback_lot_ids`: **編集前に引いていたロット** (`Stock::ReviseUsage` が渡す)。`preferred_lot_id` の次に
  優先する。編集は movement を作り直すので、これが無いとメモや用途を直しただけで別のロットに移り、
  実物のあるロットが `depleted` になったり、期限切れかどうかが変わって `q` が動いたりする。
  片づいた補填の調整ロットの id は候補に見つからないので黙って無視される。
- `on`: 使用日。補填の調整ロットの `acquired_on` になる (期限切れかどうかは「今日」で判断する)。
- **副作用**: 不足分があれば `kind: adjustment` のロットを作る (下記)。補填の入庫 movement は
  `usage_record_id` を持たせる必要があるので `Stock::UsageMovements` が作る。
- `compensate: false`: **不足しても補填しない** (引けた分だけ返し、不足は `shortage` に入れる)。
  棚卸と廃棄は「実物がこれだけだった」という記録なので、足りない分を作ってはいけない。
- `expired_first: true`: 期限切れロットを**先に**引く。廃棄は古いものから捨てるので、
  使用 (FEFO・期限切れは最後) とは順序が逆になる。
- `preferred_lot_unavailable`: 指定されたロットが (フォームを開いている間に使い切られて) 引き当てに
  使えなかった。**記録は成功させ** (設計原則 3)、「指定したロットは使い切られていたため、ほかの
  ロットから引きました」と伝える。**他の品目のロットを指定された場合は検証エラー** (422) にする
  (別の世帯のものを指すような入力で、黙って FEFO に倒すと何が起きたか分からない)。

**在庫不足時の挙動 (`Stock::Allocator`)**

```
# 在庫 2 なのに 3 使った、というケース
# -> 既存ロットから 2、不足分 1 は kind: adjustment の新規ロットを作って引く
# -> フラッシュ「在庫記録が不足していたため 1本 を調整しました」
```

これにより「使った」は必ず成功する (設計原則 3)。`adjustment` のプラス分は消費ペースの分子に入れないので、予測は歪まない ([予測](02-forecast.md) 参照)。

補填で作った調整ロットは、その使用記録を**削除・編集したときに一緒に片づける**。補填の `+movement` にも
`usage_record_id` を持たせ、movement がすべて無くなった調整ロットは削除する (残しておくと、実在しない
在庫を持つ空のロットが積み上がる)。棚卸のプラス差分で作られた調整ロットには使用記録に紐づかない入庫が
残るので、この後始末では消えない。

**ロットを手動指定したときに残数が足りない場合**は、指定したロット → FEFO の続き → 補填 の順に引く。
指定したロットに実在する在庫が残っているのに補填してしまうと、実在しない在庫が増えたうえ、
実在する在庫が使われないまま残ってしまうため。

**使用記録の編集 (`Stock::ReviseUsage`) は movement を作り直す。** FEFO の分割は数量・日付・ロット指定で
変わり、補填の調整ロットも付いたり消えたりするので、差分更新では合わせきれない。作り直すときは
「**元のロットの id を控える** → 古い movement を消す → 再計算 → 元のロットを優先して引き当て直す →
再計算」の順にする (在庫を戻す前に引き当てると、自分がさっき引いた分がもう一度必要になって
要らない補填が作られる。元のロットを優先しないと、メモを直しただけでロット別の残数が変わる)。

`Stock::ReviseLot` が直すのは**入庫の movement 1 行だけ**で、使用・廃棄・棚卸の調整はそのまま残る。
棚卸でロット別に数えるとそのロットに正の `adjustment` が足されるので、入庫は
「最初の正の movement」ではなく **`Lot#inbound_movement` (正で、`stock_take_entry_id` も
`usage_record_id` も無い最初の行)** で選ぶ。数量の検証も
**「Σ movements − 旧入庫 + 新数量 >= 0」**で行う (棚卸で足された分だけ小さい数量にも直せる)。
`rake stock:verify` の入庫の検査も同じ選び方をする。

**棚卸の確定 (`Stock::FinalizeStockTake`)**

```ruby
Stock::FinalizeStockTake.call(stock_take, user:)   # 例外: AlreadyFinalized / LedgerInconsistent
```

- 全体を 1 トランザクションで包み、**ヘッダを `lock!` してから** `finalized_at` を確認する
  (二重確定の防止。2 台で同時に確定ボタンを押されることがある)。
  `Stock::WriteStockTakeEntries` (下書きへの書き込み) と棚卸の削除も**同じようにヘッダを
  `lock!` してから確定済みかを確かめる**。確定と「途中保存」が同時に走ると、movement は
  古い差分のままで明細だけが変わり、「差分 ≠ movements の合計」が残ってしまう。
- 触る品目は **id の昇順で `lock!`** する (デッドロック防止)。`lock!` は行ロックと同時に読み直すので、
  そこから先は確定時点の値で判断できる。ロットも明細ごとにロックの後に読み直す。
- `expected_quantity` は確定時点の記録在庫 (`item.current_quantity` / `lot.remaining_quantity`) で
  取り直し、`difference = counted - expected` を入れ直す。差分 0 と未入力は movement を作らない。
- マイナス差分は `Stock::Allocator` (`compensate: false`) で FEFO に引く。**期限切れロットは最後**
  (期限切れを先に引くと、期限切れを除いて数える在庫 `q` が減らないため)。
  ロット別の明細は、そのロットからだけ引く。
- プラス差分は `kind: adjustment` の**新規ロット** (期限 NULL・価格 NULL) を作る。既存ロットに
  正の `adjustment` は付けない (`Stock::ReviseLot` の「入庫 = 最初の正の movement」を壊さないため)。
- 作った movement には必ず `stock_take_entry_id` を持たせ、`usage_record_id` は持たせない
  (使用記録に紐づけると `Stock::UsageMovements#discard!` が調整ロットごと片づけてしまう)。
- 記録在庫を引き当てきれなかったときは `LedgerInconsistent` にする。差分は記録在庫との差なので
  定義上起こらず、起きたならキャッシュと台帳がずれている (`rake stock:verify` の出番)。
  黙って補填したり、差分と movements の合計が食い違ったまま確定したりはしない。

**廃棄 (`Stock::RecordDisposal` / `Stock::DeleteDisposal`)**

- 引き当ては「ロットを指定すればそのロットから、指定が無ければ 期限切れ → FEFO の順」。
  `compensate: false` なので、**在庫記録を超える廃棄は検証エラー (422)** にする
  (「実物を捨てた」記録なので、在庫を作ってまで成功させない。設計原則 3 の例外)。
- 指定したロットの残りを超える廃棄も、他のロットには回さず検証エラーにする
  (「このロットを捨てた」という記録が別のロットの残数を減らしてしまうため)。
- 数量がロットをまたぐと movement は複数行になる。取り消し (`DELETE /disposals/:id`) は 1 行ずつなので、
  記録直後のトーストに「取り消し」を出すのは 1 行だったときだけにする。
- 廃棄は消費に数えない ([予測](02-forecast.md) 3 節) ので、`items.last_consumed_on` は動かない。

**Phase 9 から Phase 10 (予測の結線) への申し送り**

- 棚卸のマイナス差分は `kind: adjustment` かつ `quantity < 0` なので、`StockMovement.consumption`
  スコープにそのまま入る。プラス差分 (正の `adjustment`) と廃棄 (`disposal`) は入らない。
  `Forecast::SnapshotBuilder` もこのスコープを使い回すこと。
- **棚卸のマイナス差分は `counted_on` の 1 日に全量が消費として計上される。**
  3 か月ぶんの減りが 1 日に乗るので、その日の前後だけを見ると消費が極端に見える
  (窓は 90 日以上あるので合計は歪まない)。打ち間違いもそのまま予測に残り続けるため、
  確認画面で大きく減る差分に注意の印を出している (`StockTakeEntry#large_decrease?`)。
  確定済みの棚卸の取り消しは [未決事項](../plan/open-questions.md) #11。
- 1 回の棚卸で 1 品目に複数の movement が付くことがある (FEFO の分割・ロット別の明細)。
  消費イベントは `occurred_on` の重複を除いて数えるので、同じ棚卸日は 1 件になる。
- 棚卸のマイナス差分の `occurred_on` は `stock_takes.counted_on` (過去日もありうる)。
  過去日の棚卸を確定すると `items.tracking_started_on` がそれまでより前に動くことがある
  (集計窓の下限が伸びる)。`tracking_started_on` / `last_consumed_on` は
  `Stock::Recalculator` が台帳から作り直すので、古い記録を足しても正しい値に戻る。
- プラス差分で作る調整ロットは**期限 NULL** なので、期限アラート (`Expiry::Evaluator`) には
  出ないが、要購入判定の在庫 `q` には入る (期限切れではないため除外されない)。
- `u` (1 回あたりの使用数) は `usage_records.quantity` の中央値なので、**棚卸の差分は `u` に入らない**
  (消費量の分子には入る)。棚卸で大きく減らしても「1 回の使用数」は歪まない。
- 品目ごとの最終棚卸日は `Item#last_counted_on` (確定済み・実数を入れた明細だけ)。
  「直近の棚卸日より前の日付です」の警告で使っているので、予測側でも使い回せる。

**そのほかの申し送り**

- **使用記録に紐づかない `kind: usage` の movement を作らない。** `rake stock:verify` が検出する
  (既存の spec / factory が作っているので DB の check 制約にはしていない)。
- 取り消しトーストは `flash[:toast]` + `flash[:undo_path]` で描く (使用記録と廃棄で共用)。
  新しい「取り消せる記録」を足すときも、削除する URL を `undo_path` に入れるだけでよい。
- 用途 (`item_purposes`) の並べ替えは品目ごとのスコープ (`Positioned#positioned_siblings`) で動く。
  同じ仕組みで親ごとに並べ替えたいモデルが出たら、このメソッドを上書きする
  (画面の一覧に出ない行は範囲から外し、採番は `positioned_numbering_scope` で全体の末尾から振る)。

**Phase 8 から Phase 10 (予測の結線) への申し送り**

- `u` (1 回あたりの使用数) は `usage_records.quantity` の中央値、消費量は `stock_movements` の合計で、
  **別々のテーブルから数える**。両者が一致していることは `rake stock:verify` の
  「使用の数量」の検査が担保している。
- 在庫不足を補填した使用も、消費 (`StockMovement.consumption`) にはそのまま入る。
  補填の入庫は正の `adjustment` なので `consumption` スコープから外れており、分子は歪まない。

## 6. 予測が参照する値

[予測と要購入判定](02-forecast.md) の入力として、このモデルから次を取り出す。

| 予測側の名前 | 取り出し方 |
|---|---|
| `q` (在庫) | `item.current_quantity` から**期限切れロットの残数を除いた数**。`lots.expires_on < today` かつ `remaining_quantity > 0` のロットを引く |
| 消費の対象行 | `stock_movements` のうち `kind: usage` と、`kind: adjustment` かつ `quantity < 0` |
| 消費イベント | 消費の対象行がある日 (`occurred_on` の重複を除いたもの)。1 回の使用が複数行に分割されても、同じ日なら 1 件 |
| `nth_event_on` | 直近 5 件目の消費イベント日 (5 件未満なら最古) |
| `consumed` | `(window_start, today]` にある消費の対象行の絶対値合計 |
| `event_count` | `[window_start, today]` にある消費イベントの数 (窓の開始日を含む) |
| `anchor` | `item.last_consumed_on`。NULL なら `item.tracking_started_on` |
| `u` (1 回あたりの使用数) | `(window_start, today]` の `usage_records.quantity` の中央値。記録が無ければ 1 |
| `tracking_started_on` | `item.tracking_started_on` |
