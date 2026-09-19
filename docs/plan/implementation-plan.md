# 実装計画

[概要](../spec/00-overview.md) / [開発環境](../ops/development.md) / [デプロイ](../ops/deployment.md) / [未決事項](open-questions.md)

全 13 フェーズ。各フェーズは単独で動作確認してコミットできる粒度にする。t_wada 流 TDD (Red → Green → Refactor、TODO リスト駆動、小さなステップ) で進め、TDD TODO は「そのフェーズで最初に書くテスト」として使う。

| # | フェーズ | ゴール |
|---|---|---|
| 1 | 基盤整備 | 単一 DB で起動し `/up` が 200 を返す |
| 2 | テスト基盤 | `bin/rspec` が緑、CI が通る、Tailwind が効く |
| 3 | 予測ドメインロジック | DB なしで要購入判定が仕様どおりに動く |
| 4 | 認証・ユーザー管理 | ログインしてダッシュボード (ダミー) が見られる |
| 5 | Dokku 初回デプロイ | 本番でログインできる (ウォーキングスケルトン) |
| 6 | マスタと品目 | 品目とマスタの CRUD |
| 7 | 在庫台帳と購入 | 購入で在庫が増える |
| 8 | 使用記録と用途 | 1 タップで在庫が減り、取り消せる |
| 9 | 棚卸と廃棄 | 実数に合わせられる |
| 10 | 予測の結線 | ダッシュボードに要購入と期限アラートが出る |
| 11 | 買い物リスト | チェックしてそのまま購入登録 |
| 12 | PWA と Web Push | 朝 8 時に悪化したときだけ通知が届く |
| 13 | パスキー | 生体認証でログインできる |

---

## Phase 1: 基盤整備 (環境・単一 DB 化・Kamal 除去)

**ゴール**: `docker compose up` → `bin/rails s` でトップページが表示され、`/up` が 200 を返す。

**作業**

- `mise.toml` 追加 (ruby 4.0.7)
- `compose.yaml` 追加、`config/database.yml` を ENV フォールバック化 + production を単一接続に
- `solid_cable` 削除、`db/cable_schema.rb` 削除、`config/cable.yml` の production を `adapter: async` に
- `db/queue_schema.rb` / `db/cache_schema.rb` を `db/migrate/` へ取り込み、元ファイルを削除 (`force: :cascade` を必ず外す)
- `config/cache.yml` から `database: cache` を削除、`config/environments/production.rb` から `solid_queue.connects_to` を削除
- Kamal 関連ファイルを削除 (`config/deploy.yml` / `.kamal/` / `bin/kamal` / Gemfile / `.dockerignore`)
- Dockerfile の `BUNDLE_WITHOUT` を `"development:test"` に (`CMD` / `EXPOSE` は Phase 5 で決める)
- `config/application.rb` に `time_zone` / `i18n` 設定、`rails-i18n` 追加、`config/locales/ja.yml` 作成、`en.yml` 削除
- `config/tsumikura.yml` と `config_for` の初期化

**動作確認**

- `bin/rails db:prepare` で solid_queue / solid_cache のテーブルが単一 DB に作られる
- `bin/rails runner 'Rails.cache.write(:a, 1); p Rails.cache.read(:a)'` が `1` を返す
- `bin/jobs` が起動する
- `curl localhost:3000/up` が 200

---

## Phase 2: テスト基盤 (RSpec / FactoryBot / Tailwind / CI)

**ゴール**: `bin/rspec` が緑で終わり、GitHub Actions が通る。

**作業**

- `rspec-rails` / `factory_bot_rails` 追加、`rspec:install`、`bundle binstubs rspec-core`
- `test/` 削除、`spec/support/` (factory_bot, capybara) 整備、`config.generators` 設定
- `.github/workflows/ci.yml` と `config/ci.rb` を RSpec 向けに修正
- `tailwindcss-rails` 導入、レイアウトの日本語化 (`lang="ja"`、タイトル「つみくら」)
- **Ruby 4.0.7 が `ruby/setup-ruby` で使えるかをここで確認する** ([未決事項](open-questions.md) #1)

**TDD TODO**

```
- [ ] GET /up が 200 を返す
- [ ] ルートにアクセスすると「つみくら」が表示される (system spec)
- [ ] Tailwind のビルド成果物が生成されている
```

**動作確認**: `bin/ci` がローカルで通る。GitHub Actions の全ジョブが緑。

---

## Phase 3: 予測ドメインロジック (PORO のみ)

**ゴール**: DB を一切使わず、`Forecast::Calculator` が [予測仕様](../spec/02-forecast.md) どおりに判定できる。ここが本アプリの心臓であり、依存が最も少ないので先に完成させる。

**作業**

- `app/models/forecast/{thresholds,pace,snapshot,result,window,calculator}.rb`
- `spec/models/forecast/*_spec.rb` (`rails_helper` 不要、`spec_helper` のみ。ActiveSupport の拡張にも依存させない)

**TDD TODO**

```
閾値と既定値
- [ ] Forecast::Thresholds.default は soon 21 / urgent 7 / window_min 90 /
      window_events 5 / window_max 730 / min_samples 2 / min_observed_days 14 を返す
- [ ] 品目固有の閾値 (soon 30 / urgent 10) が既定値を上書きする

窓 (Forecast::Window)
- [ ] 消費イベントが十分あるとき (5 件目が 22 日前)、窓の開始は today - 90 日、終わりは today
- [ ] 消費イベントが 1 件も無いとき、窓の開始は today - 90 日
- [ ] 5 件目の消費イベントが 200 日前なら、窓の開始は 200 日前まで伸びる
- [ ] 消費イベントが 3 件しかなければ、最古の消費イベント日まで伸びる
- [ ] tracking_started_on が 30 日前なら、窓の開始は 30 日前で止まる
- [ ] 5 件目の消費イベントが 900 日前でも、窓の開始は today - 730 日で止まる
- [ ] tracking_started_on が nil なら、下限は today - 730 日だけになる
- [ ] 窓の開始が nth_event_on と一致するとき、窓の終わりは last_event_on (anchor) になる
- [ ] 窓の開始が today - 90 日や下限で決まったとき、窓の終わりは today になる
- [ ] observed_days は 窓の終わり - 窓の開始 (+1 しない)
- [ ] 検算例 2: イベントが today / 182 / 364 / 546 / 728 日前なら、開始 728 日前・終わり today・observed_days 728

ペース
- [ ] event_count 1 なら pace は unknown
- [ ] event_count 0 なら pace は unknown (0 とは扱わない)
- [ ] event_count 2・observed_days 13 なら pace は unknown
- [ ] event_count 2・observed_days 14 なら pace は既知 (全 2 件で古い方が窓の開始、というケース)
- [ ] 観測 90 日・消費 18 個なら pace.per_day は Rational(1, 5) (検算例 1)
- [ ] 観測 728 日・消費 4 個なら pace.per_day は Rational(1, 182) (検算例 2)

在庫切れ予測日 (need_by_on)
- [ ] 在庫 3・u 1・pace 1/5・anchor 2 日前 なら need_by_on は today + 18 で soon (検算例 1)
- [ ] 在庫 0・u 1・pace 1/182・anchor today なら need_by_on は today + 182 で ok (検算例 2)
- [ ] 在庫 5・u 2・pace 1/10 なら need_by_on は anchor + 60 (検算例 3)
- [ ] u が 2 のとき、在庫 5 では「あと 2 回」として計算される (端数は数えない)
- [ ] 在庫 1・u 2 (在庫が 1 回分に満たない) なら、在庫 0 と同じ need_by_on になる
- [ ] 日数は切り上げる (pace 4/729 なら 1 個あたり 183 日)
- [ ] need_by_on が過去になる場合は today に丸められ、days_left は 0 で urgent
- [ ] days_left 7 は urgent、8 は soon、21 は soon、22 は ok

在庫 0
- [ ] 在庫 0 でペース不明なら urgent、reason は :out_of_stock
- [ ] 在庫 0 でもペースが分かっていれば式どおりに判定する (urgent 固定にしない)
- [ ] none モードでは在庫 0 でも urgent にしない (最低在庫未設定なら unknown)

最低在庫数
- [ ] 最低在庫 3・在庫 2 なら urgent
- [ ] 最低在庫 3・在庫 3 なら soon
- [ ] 最低在庫 3・在庫 4 なら ok
- [ ] pace 判定 ok かつ最低在庫判定 urgent なら結果は urgent、reason は :minimum (悪い方を採用)
- [ ] pace 判定 urgent かつ最低在庫判定 ok なら結果は urgent、reason は :pace
- [ ] pace unknown かつ最低在庫未設定かつ在庫ありなら unknown、reason は :no_data

モード
- [ ] manual モード: manual_interval_days 5 なら pace.per_day は Rational(1, 5)
- [ ] manual モード: event_count 0・observed_days 0 でも pace は既知
- [ ] manual モード: manual_interval_days 未設定なら unknown
- [ ] manual モード: anchor_on が nil なら unknown
- [ ] none モード: pace は常に unknown で、最低在庫数だけで判定する
```

**動作確認**: `bin/rspec spec/models/forecast` が DB 未起動でも通り、1 秒未満で終わる。

---

## Phase 4: 認証・ユーザー管理・レイアウト骨格

**ゴール**: ログインしてダッシュボード (ダミー) を見られる。管理者が家族アカウントを追加できる。

**作業**

- `bin/rails generate authentication` → `PasswordsController` / `PasswordsMailer` / 関連ビュー・ルートを削除
- `users` に `name` / `role` / `deactivated_at` / 通知フラグを追加する migration
- `Admin::UsersController` (管理者のみ)、`Admin::PasswordResetsController` (新パスワード生成 → 画面表示)
- `lib/tasks/tsumikura.rake` に `tsumikura:create_admin`、`db/seeds.rb` を冪等に
- `/account` (表示名・パスワード変更・ログイン中セッション一覧)
- 下部タブナビとレイアウト骨格、ダッシュボードのダミー

**TDD TODO**

```
- [ ] 未ログインで / にアクセスするとログイン画面にリダイレクトされる
- [ ] 正しいメールアドレスとパスワードでログインするとダッシュボードに遷移する
- [ ] 誤ったパスワードではログインできない
- [ ] User#admin? は role が admin のとき true
- [ ] 一般ユーザーが /admin/users にアクセスすると 403
- [ ] 管理者はユーザーを作成でき、生成された初期パスワードが 1 度だけ表示される
- [ ] 管理者はパスワードを再設定でき、対象ユーザーの既存セッションが失効する
- [ ] 無効化されたユーザーはログインできない
- [ ] 管理者が 1 人のとき、その管理者は降格できない
- [ ] 管理者が 1 人のとき、その管理者は無効化できない
- [ ] /account でセッションを個別に失効できる
- [ ] tsumikura:create_admin タスクは冪等 (2 回実行してもユーザーが重複しない)
```

**動作確認**: 管理者を作り、家族ユーザーを追加して両方でログインできる。

---

## Phase 5: Dokku 初回デプロイ (ウォーキングスケルトン)

**ゴール**: ログインだけできる状態を本番に出し、デプロイ経路を早期に固める。

**作業**

- **Thruster を残すか外すかを決める** ([デプロイ](../ops/deployment.md) の案 A / 案 B)。決めた内容で `Dockerfile` の `CMD` / `EXPOSE`、Gemfile、`bin/thrust` を確定し、`docs/ops/deployment.md` と [未決事項](open-questions.md) を更新する
- `app.json` (predeploy / healthchecks) 作成
- `config/environments/production.rb` の `assume_ssl` / `force_ssl` / `ssl_options` / `hosts` を有効化
- `bin/docker-entrypoint` から `db:prepare` を削除
- Dokku 側セットアップ (app 作成、postgres link、domains、letsencrypt、config:set)
- 初回デプロイ + `dokku run ... tsumikura:create_admin`
- **DB の日次バックアップをここで設定する** (後回しにしない)

**動作確認**: `https://tsumikura.example.com/up` が 200、ログインできる、`dokku logs` にジョブ supervisor の起動ログが出る、バックアップが 1 回取れている。

---

## Phase 6: マスタと品目

**ゴール**: カテゴリ・保管場所・店舗・品目の CRUD が動く。

**作業**

- `categories` / `storage_locations` / `stores` / `items` の migration とモデル (外部キーは `on_delete: :nullify`)
- `ItemsController` (index/show/new/create/edit/update/destroy)、検索・フィルタ
- 各マスタの CRUD (並べ替え、削除時の確認)

**TDD TODO**

```
- [ ] Item は name が必須
- [ ] Item は unit が必須で既定値は "個"
- [ ] Item.active は archived_at が nil のものだけを返す
- [ ] 品目一覧でカテゴリ絞り込みができる
- [ ] 品目一覧で名前とよみで検索できる
- [ ] 使用中のカテゴリを削除すると、その品目の category_id が nil になる (nullify)
- [ ] 使用中の保管場所・店舗も同様に nullify される
- [ ] 品目をアーカイブすると一覧に出ないが、詳細は開ける
- [ ] 品目を作成すると current_quantity は 0
```

**動作確認**: 品目を 5 件ほど登録し、カテゴリで絞り込める。

---

## Phase 7: 在庫台帳と購入

**ゴール**: 購入を入力すると在庫が増え、ロット一覧に表示される。初期在庫も入れられる。

**作業**

- `lots` / `stock_movements` の migration とモデル
- `Stock::Recalculator` / `Stock::RecordPurchase`
- `LotsController#new/create/edit/update/destroy`
- 「入数 × パック数 / 直接入力」トグルの Stimulus コントローラ
- `lib/tasks/stock.rake` に `stock:verify` / `stock:recalculate`

**TDD TODO**

```
- [ ] StockMovement は quantity が 0 では保存できない
- [ ] 購入を記録すると Lot が 1 件と StockMovement(purchase, +12) が 1 件作られる
- [ ] 購入を記録すると lot.remaining_quantity が 12 になる
- [ ] 購入を記録すると item.current_quantity が 12 になる
- [ ] 2 回購入すると item.current_quantity は合計になる
- [ ] 入数 12 × パック数 2 で数量 24 の Lot が作られる
- [ ] 購入記録を削除すると在庫が元に戻る
- [ ] 購入記録の数量を編集すると在庫が再計算される
- [ ] item.tracking_started_on は最も古い StockMovement の occurred_on になる
- [ ] 未来の日付の購入は保存できない
- [ ] Stock::Recalculator はキャッシュがずれていても台帳から正しい値に戻す
- [ ] stock:verify はキャッシュと台帳の差異を検出する
```

**動作確認**: 購入を 2 回入れて在庫が合計になる。`stock:verify` が差異 0 を報告する。

---

## Phase 8: 使用記録と用途

**ゴール**: 品目一覧の「使った」ボタン 1 タップで在庫が減り、取り消せる。用途つきの記録もできる。

**作業**

- `usage_records` / `item_purposes` の migration とモデル
- `Stock::Allocator` (FEFO + 在庫不足時の自動調整ロット)
- `Stock::RecordUsage` / `Stock::ReviseUsage` / `Stock::DeleteMovement`
- `UsageRecordsController`、`ItemsController#quick_use` (Turbo Stream + 取り消しトースト)
- 用途別の交換履歴と交換周期 (中央値) の表示
- ロットの削除・数量編集の制限

**TDD TODO**

```
- [ ] Stock::Allocator は期限が近いロットから引き当てる
- [ ] Stock::Allocator は期限 nil のロットを期限つきロットの後に引き当てる
- [ ] Stock::Allocator は期限切れロットを最後に引き当てる
- [ ] 期限が同じなら購入が古いロットから引き当てる
- [ ] 在庫 5 のロットに対して 3 使うと、そのロットから 3 だけ引かれる
- [ ] ロット A に 2・ロット B に 5 あるとき 4 使うと、A から 2・B から 2 に分割される
- [ ] 分割されても UsageRecord は 1 件、StockMovement は 2 件
- [ ] 在庫 2 に対して 3 使うと kind: adjustment のロットが 1 件作られ、不足 1 が補われる
- [ ] 使用記録を作ると item.last_consumed_on が used_on になる
- [ ] 過去日 (3 日前) の使用記録を作っても現在庫は正しく減る
- [ ] 未来の日付の使用記録は保存できない
- [ ] 最新の使用記録を削除すると item.last_consumed_on は 1 つ前の消費日に戻る
- [ ] 使用記録を削除すると在庫が戻り、分割された StockMovement もすべて消える
- [ ] 使用済みのロットは削除できない (バリデーションエラー)
- [ ] ロットの数量を、既に使われた数より小さくは編集できない
- [ ] 用途を指定した使用記録は item_purpose_id を持つ
- [ ] ItemPurpose#replacement_interval_days は used_on の差分の中央値を返す
- [ ] 使用記録が 1 件の用途は interval を返さず、最終使用日だけを返す
```

**動作確認**: スマホ幅で品目一覧の「使った」を押すと在庫が 1 減り、トーストの「取り消し」で戻る。

---

## Phase 9: 棚卸と廃棄

**ゴール**: 保管場所ごとに棚卸して在庫を合わせられる。期限切れを廃棄できる。

**作業**

- `stock_takes` / `stock_take_entries` の migration とモデル
- `Stock::FinalizeStockTake` (マイナス差分は FEFO、プラス差分は調整ロット)
- `StockTakesController` + `StockTakes::FinalizationsController`
- ロット別入力の展開 UI
- `Stock::RecordDisposal` / `DisposalsController`

**TDD TODO**

```
- [ ] 下書きの棚卸は在庫に影響しない
- [ ] 記録在庫 10・実数 7 の棚卸を確定すると difference は -3
- [ ] マイナス差分は期限の近いロットから引かれる
- [ ] 記録在庫 10・実数 12 の棚卸を確定すると kind: adjustment のロットが 1 件
      (数量 2、期限 nil) 作られる
- [ ] 差分 0 の明細は StockMovement を作らない
- [ ] 実数未入力 (counted_quantity が nil) の品目はスキップされる
- [ ] 保管場所を指定した棚卸には、その場所の品目だけが並ぶ
- [ ] 廃棄を記録すると在庫が減り、kind: disposal の StockMovement が作られる
- [ ] 棚卸のマイナス差分は item.last_consumed_on を更新する
- [ ] 廃棄は item.last_consumed_on を更新しない
```

**動作確認**: 保管場所を選んで数件を数え、確定すると在庫が実数に一致する。

---

## Phase 10: 予測の結線とダッシュボード

**ゴール**: ダッシュボードに要購入と期限アラートが表示される。品目詳細に在庫切れ予測日が出る。

**作業**

- `Forecast::SnapshotBuilder` / `ItemForecaster` / `BatchForecaster` (一覧用の一括集計クエリ)
- `Expiry::Evaluator` (期限ステータス)
- `DashboardsController` + ダッシュボード UI
- 品目一覧・詳細へのステータスバッジ組み込み
- 品目編集に予測設定 (`estimation_mode` / `manual_interval_days` / 閾値 / 最低在庫数 / 期限警告日数)

**TDD TODO**

```
- [ ] SnapshotBuilder は usage と負の adjustment を消費量に含める
- [ ] SnapshotBuilder は disposal を消費量に含めない
- [ ] SnapshotBuilder は purchase と正の adjustment を消費量に含めない
- [ ] 同じ日の複数の消費記録は消費イベント 1 件と数える (FEFO で 2 行に分割された使用も 1 件)
- [ ] SnapshotBuilder の窓は直近 5 件目の消費イベント日まで伸びる
- [ ] SnapshotBuilder の窓は tracking_started_on より前には遡らない
- [ ] SnapshotBuilder の窓は today - 730 日より前には遡らない
- [ ] 窓の開始日当日の消費は consumed に含まれないが、event_count には含まれる
- [ ] 窓の開始日より古い使用記録は consumed にも event_count にも含まれない
- [ ] 182 日おきに 5 回使った品目 (最後が today) は consumed 4・event_count 5・observed_days 728 になる (検算例 2)
- [ ] 5 日おきに使っている品目 (最後が 2 日前) は consumed 18・observed_days 90 になる (検算例 1)
- [ ] SnapshotBuilder の quantity は期限切れロットの残数を除く
- [ ] 全ロットが期限切れなら quantity は 0 になる
- [ ] SnapshotBuilder の unit_usage は窓内の使用記録の数量の中央値 (無ければ 1)
- [ ] SnapshotBuilder の anchor_on は最後の消費イベント日 (棚卸のマイナス差分を含む)
- [ ] 消費イベントが無い品目の anchor_on は tracking_started_on
- [ ] BatchForecaster の結果は、各品目を ItemForecaster で個別に判定した結果と一致する
- [ ] BatchForecaster は N 品目に対してクエリを定数回しか発行しない
- [ ] ダッシュボードに購入推奨の品目数が表示される
- [ ] ダッシュボードに期限切れロットを持つ品目が表示される
- [ ] unknown の品目はダッシュボードの要購入に出ない
- [ ] 品目詳細に在庫切れ予測日と残り日数が表示される
```

**動作確認**: 実データ (数品目) で予測日が [検算例](../spec/02-forecast.md) と一致する。

---

## Phase 11: 買い物リスト

**ゴール**: 要購入品目が自動で並び、チェックしてそのまま購入登録できる。

**作業**

- `shopping_list_items` の migration とモデル
- `ShoppingLists::Builder` (導出 + 永続行のマージ)
- `ShoppingListsController` / `ShoppingListItemsController`
- `PurchasesController#new/create` (チェック済みからまとめて Lot 作成)
- スヌーズ、手動追加 (自由入力)

**TDD TODO**

```
- [ ] status が urgent の品目は買い物リストに自動で並ぶ
- [ ] status が soon の品目も並ぶ (ok / unknown は並ばない)
- [ ] 手動追加した自由入力の行が並ぶ
- [ ] スヌーズした品目は snoozed_until まで並ばない
- [ ] チェックすると shopping_list_items に行が作られる
- [ ] チェック済み行から購入を登録すると Lot が作られ、行が消える
- [ ] 購入登録後は在庫が増え、ステータスが ok に戻る
- [ ] アーカイブ済みの品目は並ばない
```

**動作確認**: 買い物リストからまとめ購入を登録し、在庫が増えてリストから消える。

---

## Phase 12: PWA と Web Push

**ゴール**: ホーム画面に追加でき、朝 8 時に「状態が悪化したときだけ」通知が届く。

**作業**

- manifest / service-worker の有効化、アイコン差し替え、routes とレイアウトのコメント解除
- `web-push` gem、`web_push_subscriptions` / `item_alert_states` の migration
- `WebPushSubscriptionsController` + `push_subscription_controller.js`
- `WebPushDeliveryJob` / `DailyDigestJob`
- `config/recurring.yml` に日次ダイジェスト
- `/account` の通知セクション (テスト送信ボタン、iOS 案内)

**TDD TODO**

```
- [ ] 購読を登録すると WebPushSubscription が作られる
- [ ] 同じ endpoint で 2 回購読しても行は 1 件のまま (upsert)
- [ ] 配信で ExpiredSubscription が起きたら購読が削除される
- [ ] DailyDigestJob は状態が悪化した品目が 0 件なら何も送らない
- [ ] ok -> urgent に悪化した品目があれば 1 通送る
- [ ] 同じ品目が 2 日連続で urgent なら 2 日目は送らない
- [ ] urgent -> ok -> urgent と戻ると再度送られる
- [ ] notify_purchases が false のユーザーには要購入の通知を送らない
- [ ] 送信後に item_alert_states が現在値で更新される
```

**動作確認**: 本番にデプロイし、スマホをホーム画面に追加してテスト送信が届く。

---

## Phase 13: パスキー

**ゴール**: スマホの生体認証でログインできる。

**作業**

- `webauthn` gem、`passkeys` の migration、`users.webauthn_id`
- `config/initializers/webauthn.rb`
- `PasskeysController` (一覧/options/create/destroy) + `Sessions::PasskeysController` (options/create)
- `passkey_controller.js` (登録/認証)、ログイン画面の conditional UI
- `spec/support/webauthn_helper.rb` (`WebAuthn::FakeClient`)

**TDD TODO**

```
- [ ] ログイン済みユーザーは登録オプションを取得できる
- [ ] FakeClient で作った credential を登録すると Passkey が作られる
- [ ] challenge が一致しない credential は登録を拒否される
- [ ] 登録済みのパスキーで usernameless ログインできる
- [ ] 存在しない external_id でのログインは拒否される
- [ ] 無効化されたユーザーのパスキーではログインできない
- [ ] ログイン成功で passkey.last_used_at と sign_count が更新される
- [ ] パスキーを削除すると、それでログインできなくなる
- [ ] 未ログインでも /sessions/passkey/options にアクセスできる
```

**動作確認**: 本番の HTTPS 環境でスマホにパスキーを登録し、メール入力なしでログインできる。

---

## 付録 A: 変更が必要な既存ファイル

| ファイル | 変更内容 | フェーズ |
|---|---|---|
| `config/database.yml` | development/test に ENV フォールバック、production を単一接続に | 1 |
| `config/cache.yml` | production から `database: cache` を削除 | 1 |
| `config/cable.yml` | production を `adapter: async` に | 1 |
| `config/environments/production.rb` | `solid_queue.connects_to` 削除、`assume_ssl`/`force_ssl`/`ssl_options`/`hosts` 有効化 | 1, 5 |
| `config/application.rb` | `time_zone`、`i18n`、`config.generators` | 1, 2 |
| `config/routes.rb` | root、PWA 2 行のコメント解除、全ルート追加 | 1, 4〜13 |
| `config/recurring.yml` | `daily_digest` 追加 | 12 |
| `config/ci.rb` | Minitest → RSpec | 2 |
| `.github/workflows/ci.yml` | `test` / `system-test` を RSpec に、artifact path 変更 | 2 |
| `Gemfile` | `kamal` / `solid_cable` 削除、`rspec-rails` / `factory_bot_rails` / `tailwindcss-rails` / `rails-i18n` / `web-push` / `webauthn` 追加。`thruster` は Phase 5 の決定次第 | 1〜13 |
| `Dockerfile` | `BUNDLE_WITHOUT="development:test"` (1)、`CMD` / `EXPOSE` は Thruster の決定次第 (5) | 1, 5 |
| `bin/docker-entrypoint` | `db:prepare` を削除 (app.json の predeploy に移管) | 5 |
| `.dockerignore` | Kamal ブロック削除 | 1 |
| `app/views/layouts/application.html.erb` | `lang="ja"`、タイトル、manifest link 有効化、下部タブ、Tailwind | 2, 4, 12 |
| `app/views/pwa/manifest.json.erb` | 日本語名・アイコン・shortcuts | 12 |
| `app/views/pwa/service-worker.js` | push / notificationclick のコメント解除 | 12 |
| `db/seeds.rb` | 冪等な実装 | 4 |
| `public/icon.png` / `icon.svg` | つみくらのアイコンに差し替え、192px 追加 | 12 |
| `config/locales/en.yml` | 削除 (`ja.yml` に置換) | 1 |

## 付録 B: 削除するファイル

`config/deploy.yml`、`.kamal/`、`bin/kamal`、`db/queue_schema.rb`、`db/cache_schema.rb`、`db/cable_schema.rb`、`test/` 一式、`app/controllers/passwords_controller.rb` (生成後)、`app/mailers/passwords_mailer.rb` (生成後)、`app/views/passwords_mailer/`。
Thruster を外すと決めた場合は `bin/thrust` も削除する (Phase 5)。

## 付録 C: 新規作成するファイル (設定系)

`mise.toml`、`compose.yaml`、`app.json`、`config/tsumikura.yml`、`config/initializers/webauthn.rb`、`config/initializers/web_push.rb`、`lib/tasks/tsumikura.rake`、`lib/tasks/stock.rake`。
