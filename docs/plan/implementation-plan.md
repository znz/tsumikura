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
- [x] Forecast::Thresholds.default は soon 21 / urgent 7 / window_min 90 /
      window_events 5 / window_max 730 / min_samples 2 / min_observed_days 14 を返す
- [x] 品目固有の閾値 (soon 30 / urgent 10) が既定値を上書きする
- [x] 上書きしても既定値のオブジェクトは変わらない (メモ化した default を壊さない)
- [x] min_samples が 2 未満なら ArgumentError
- [x] min_observed_days が 1 未満なら ArgumentError (ゼロ除算の予防)

窓 (Forecast::Window)
- [x] 消費イベントが十分あるとき (5 件目が 22 日前)、窓の開始は today - 90 日、終わりは today
- [x] 消費イベントが 1 件も無いとき、窓の開始は today - 90 日
- [x] 5 件目の消費イベントが 200 日前なら、窓の開始は 200 日前まで伸びる
- [x] 消費イベントが 3 件しかなければ、最古の消費イベント日まで伸びる
- [x] tracking_started_on が 30 日前なら、窓の開始は 30 日前で止まる
- [x] 5 件目の消費イベントが 900 日前でも、窓の開始は today - 730 日で止まる
- [x] tracking_started_on が nil なら、下限は today - 730 日だけになる
- [x] 窓の開始が nth_event_on と一致するとき、窓の終わりは last_event_on (anchor) になる
- [x] 窓の開始が today - 90 日や下限で決まったとき、窓の終わりは today になる
- [x] observed_days は 窓の終わり - 窓の開始 (+1 しない)
- [x] 検算例 2: イベントが today / 182 / 364 / 546 / 728 日前なら、開始 728 日前・終わり today・observed_days 728
- [x] 境界: 5 件目が 89 日前なら today - 90 日のまま、91 日前ならそこまで伸びる
- [x] 境界: 5 件目がちょうど 730 日前ならその日、731 日前なら today - 730 日
- [x] 窓の開始が下限 (tracking_started_on / today - 730 日) で決まったときの終わりは today
- [x] 境界: 5 件目がちょうど today - 90 日なら、終わりは last_event_on になる
- [x] 境界: 5 件目がちょうど 730 日前なら、終わりは last_event_on になる
- [x] 境界: nth_event_on と tracking_started_on が同じ日なら、終わりは last_event_on になる
- [x] window_min_days / window_max_days は Thresholds.default 固定ではなく渡された閾値を見る

ペース
- [x] event_count 1 なら pace は unknown
- [x] event_count 0 なら pace は unknown (0 とは扱わない)
- [x] event_count 2・observed_days 13 なら pace は unknown
- [x] event_count 2・observed_days 14 なら pace は既知 (全 2 件で古い方が窓の開始、というケース)
- [x] 観測 90 日・消費 18 個なら pace.per_day は Rational(1, 5) (検算例 1)
- [x] 観測 728 日・消費 4 個なら pace.per_day は Rational(1, 182) (検算例 2)
- [x] unknown のとき source は :unknown、per_day は nil
- [x] min_samples / min_observed_days は Thresholds.default 固定ではなく Snapshot の閾値を見る
- [x] auto モードでも anchor_on が nil なら unknown (キャッシュずれで例外にしない)
- [x] mode が Symbol 以外 (AR の enum 文字列) や nil なら ArgumentError

在庫切れ予測日 (need_by_on)
- [x] 在庫 3・u 1・pace 1/5・anchor 2 日前 なら need_by_on は today + 18 で soon (検算例 1)
- [x] 在庫 0・u 1・pace 1/182・anchor today なら need_by_on は today + 182 で ok (検算例 2)
- [x] 在庫 5・u 2・pace 1/10 なら need_by_on は anchor + 60 (検算例 3)
- [x] u が 2 のとき、在庫 5 では「あと 2 回」として計算される (端数は数えない)
- [x] 在庫 1・u 2 (在庫が 1 回分に満たない) なら、在庫 0 と同じ need_by_on になる
- [x] 日数は切り上げる (pace 4/729 なら 1 個あたり 183 日)
- [x] need_by_on が過去になる場合は today に丸められ、days_left は 0 で urgent
- [x] days_left 7 は urgent、8 は soon、21 は soon、22 は ok
- [x] 品目固有の閾値 (soon 30 / urgent 10) では既定と結果が分かれる
      (days_left 9 は urgent、25 は soon。既定なら soon / ok)
- [x] ペースは Rational なので切り上げがずれない (消費 1・観測 49 日で need_by_on は today + 49)
- [x] 在庫が Float でも「あと何回使えるか」は整数除算になる

在庫 0
- [x] 在庫 0 でペース不明なら urgent、reason は :out_of_stock
- [x] 在庫 0 でもペースが分かっていれば式どおりに判定する (urgent 固定にしない)
- [x] none モードでは在庫 0 でも urgent にしない (最低在庫未設定なら unknown)
- [x] 在庫 0・ペース不明・最低在庫ありなら reason は :out_of_stock を優先する
- [x] manual モードでも anchor が無ければペース不明なので在庫 0 は urgent

最低在庫数
- [x] 最低在庫 3・在庫 2 なら urgent
- [x] 最低在庫 3・在庫 3 なら soon
- [x] 最低在庫 3・在庫 4 なら ok
- [x] pace 判定 ok かつ最低在庫判定 urgent なら結果は urgent、reason は :minimum (悪い方を採用)
- [x] pace 判定 urgent かつ最低在庫判定 ok なら結果は urgent、reason は :pace
- [x] pace unknown かつ最低在庫未設定かつ在庫ありなら unknown、reason は :no_data
- [x] ペースが分かっていれば reason が :minimum でも need_by_on と days_left を返す
- [x] 両方 soon なら reason は :minimum を優先する
- [x] pace 判定 ok かつ最低在庫判定 soon なら soon、reason は :minimum
- [x] pace 判定 soon かつ最低在庫判定 ok なら soon、reason は :pace

モード
- [x] manual モード: manual_interval_days 5 なら pace.per_day は Rational(1, 5)
- [x] manual モード: event_count 0・observed_days 0 でも pace は既知
- [x] manual モード: manual_interval_days 未設定なら unknown
- [x] manual モード: anchor_on が nil なら unknown
- [x] manual モード: 実績が無くても need_by_on を出す
- [x] manual モード: u が 2 でもペースは 1 / manual_interval_days のまま
- [x] manual モード: 在庫 0 でもペース既知なら reason は :pace (:out_of_stock にしない)
- [x] manual モード: anchor が古い tracking_started_on なら need_by_on は today に丸められる
- [x] none モード: pace は常に unknown で、最低在庫数だけで判定する
- [x] none モード: 在庫と最低在庫が同数なら soon

エッジケース (仕様 9 節のうち PORO で表現できる行)
- [x] 2 年以上使っていない (消費イベント 0 件) なら unknown で、最低在庫数だけで判定する
- [x] 登録初日に大量使用しても observed_days が足りず極端なペースは出ない
- [x] anchor_on が nil (キャッシュずれ) でも例外にならず unknown になる
```

仕様 9 節の残りの行は AR 側の責務なので、それぞれ次のフェーズの TODO で扱う。
同じ日の複数記録を 1 件と数える / 全ロット期限切れなら q = 0 は Phase 10、
未来日の記録を作れないことは Phase 7 (購入) と Phase 8 (使用)、
アーカイブ済み品目を一覧から外すことは Phase 6、買い物リストから外すことは Phase 11。
期限判定 (仕様 12 節) は Phase 10 の `Expiry::Evaluator`。

**動作確認**: `bin/rspec spec/models/forecast` が DB 未起動でも通り、1 秒未満で終わる。

---

## Phase 4: 認証・ユーザー管理・レイアウト骨格

**ゴール**: ログインしてダッシュボード (ダミー) を見られる。管理者が家族アカウントを追加できる。

**作業**

- `bin/rails generate authentication` → `PasswordsController` / `PasswordsMailer` / 関連ビュー・ルートを削除。
  Action Cable を使わない方針なので `app/channels/` も削除する
- `users` に `name` / `role` / `deactivated_at` / 通知フラグを追加する migration
  (`webauthn_id` は Phase 13)
- `User` に `enum :role` / `active` スコープ / バリデーション / 最後の管理者の保護
- 無効化ユーザーのログイン拒否 (`SessionsController#create`) とセッション復元の拒否 (`Session.active`)
- `Admin::BaseController` (管理者以外は 403)、`Admin::UsersController` (一覧・追加・編集)、
  `Admin::DeactivationsController` (無効化 / 再有効化)、`Admin::PasswordResetsController` (新パスワード生成 → 画面表示)
- `lib/tasks/tsumikura.rake` に `tsumikura:create_admin`、`db/seeds.rb` を冪等に
- `/account` (`AccountsController`) + `Account::PasswordsController` (現在のパスワード確認つき) +
  `Account::SessionsController` (個別失効 / このデバイス以外をログアウト)
- 下部タブナビとレイアウト骨格 (`MenusController`)、ダッシュボードのダミー
- `spec/support/authentication_helper.rb` (request 用 `sign_in` / system 用 `sign_in_as`)

**TDD TODO**

```
ログインとセッション (spec/requests/sessions_spec.rb)
- [x] 未ログインで / にアクセスするとログイン画面にリダイレクトされる
- [x] 正しいメールアドレスとパスワードでログインするとダッシュボードに遷移する
- [x] ログイン前にアクセスしようとした URL に戻る (reset_session で失わない)
- [x] GET 以外で認証を要求されたときは、その URL を復帰先にしない
- [x] 誤ったパスワードではログインできない
- [x] 無効化されたユーザーはログインできない
- [x] 無効化されたユーザーのエラーメッセージはパスワード誤りと区別できない
- [x] ログイン後に無効化されると、既存のセッションでもアクセスできない
- [x] ログアウトするとセッションが削除され、/ にアクセスできなくなる
- [x] ログアウトのお知らせが reset_session で消えない
- [x] セッション cookie に httponly と SameSite=Lax が付く
- [x] ログイン試行に rate_limit が掛かっている
- [x] 壊れたパラメータ (配列・欠落) でログインすると 400 (500 にしない)
- [x] /cable はマウントされていない (spec/requests/action_cable_spec.rb)

User モデル (spec/models/user_spec.rb)
- [x] User#admin? は role が admin のとき true
- [x] 表示名は必須
- [x] メールアドレスは形式を検査し、大文字小文字を無視して一意
- [x] パスワードは最小長 (User::MINIMUM_PASSWORD_LENGTH) 以上
- [x] User.active は無効化されていないユーザーだけを返す
- [x] 管理者が 1 人のとき、その管理者は降格できない
- [x] 管理者が 1 人のとき、その管理者は無効化できない
- [x] 無効化済みの管理者は「有効な管理者」に数えない
- [x] User.generate_password は読み間違えにくい文字種で十分な長さのパスワードを返す

ユーザー管理 (spec/requests/admin/*_spec.rb)
- [x] 一般ユーザーが /admin/users にアクセスすると 403
- [x] 一般ユーザーは管理画面の全アクション (9 種) が 403 で、役割も状態も変わらない (表駆動)
- [x] 未ログインでは管理画面の全アクションがログイン画面にリダイレクトされる (表駆動)
- [x] 管理者はユーザーを作成でき、生成された初期パスワードが 1 度だけ表示される
- [x] 初期パスワードは flash に載せず、一覧を開いても再表示されない
- [x] 生成パスワードの画面は no-store で、Turbo のスナップショットにも残さない
- [x] 追加フォームだけ Turbo を外し、編集フォームは通常どおり動く
- [x] 実ブラウザでも初期パスワード / 新パスワードが表示される (js: true の system spec)
- [x] 表示された初期パスワードでログインできる
- [x] 編集では役割を変更でき、パスワードと無効化は変更できない (mass assignment の遮断)
- [x] 管理者はユーザーを無効化・再有効化でき、無効化で対象の全セッションが失効する
- [x] 管理者はパスワードを再設定でき、対象ユーザーの既存セッションが失効する
- [x] 再設定した新しいパスワードも 1 度だけ表示される
- [x] 自分自身へのパスワード再設定はアカウント設定に案内され、一覧にも出ない
- [x] 自分自身の無効化ボタンは一覧に出ない

アカウント設定 (spec/requests/accounts_spec.rb)
- [x] 表示名とメールアドレスを変更できる
- [x] 自分で役割や無効化を変更することはできない
- [x] パスワード変更には現在のパスワードの確認が必要
- [x] 新しいパスワードが空 / 未送信なら変更できない (無変更で成功扱いにしない)
- [x] パスワードを変更するとこのデバイス以外のセッションが失効し、現在のセッションは残る
- [x] パスワード変更の失敗ではセッションを失効させない
- [x] パスワード変更に rate_limit が掛かっている
- [x] ログイン中のセッションが一覧され、現在のセッションにだけ印が付く
- [x] /account でセッションを個別に失効できる
- [x] このデバイス以外をすべてログアウトできる

rake タスク (spec/tasks/create_admin_spec.rb)
- [x] tsumikura:create_admin タスクは冪等 (2 回実行してもユーザーが重複しない)
- [x] ADMIN_EMAIL が無ければ中断する
- [x] 自動生成したパスワードを標準出力に 1 度だけ表示する
- [x] 既存の一般ユーザーは管理者に昇格する (パスワードは変えない)
- [x] ADMIN_RESET_PASSWORD=1 でパスワードを再生成し、セッションを失効させる
- [x] ADMIN_PASSWORD での再設定でもセッションを失効させる
- [x] 無効化済みユーザーは再有効化せず、警告と代替手段を表示する
- [x] バリデーションエラーはスタックトレースではなく中断で返す

レイアウト (spec/system/*_spec.rb)
- [x] 未ログインでトップにアクセスするとログイン画面が表示される
- [x] ログイン後はダッシュボードと下部 5 タブが表示される
- [x] 未ログインのログイン画面にはタブを出さない
- [x] 未実装のタブ (品目・買い物・記録) はリンクにせず、準備中だと伝える
- [x] 下部タブは safe-area の余白を持ち、viewport は viewport-fit=cover
- [x] メニューからアカウント設定・ログアウトに行ける
- [x] 一般ユーザーにはユーザー管理のリンクが見えない
```

**動作確認**: 管理者を作り、家族ユーザーを追加して両方でログインできる。

---

## Phase 5: Dokku 初回デプロイ (ウォーキングスケルトン)

**ゴール**: ログインだけできる状態を本番に出し、デプロイ経路を早期に固める。

**作業**

- **リポジトリ側の準備は完了**: `app.json` (predeploy / healthchecks) 作成、`config/environments/production.rb` の `assume_ssl` / `force_ssl` / `ssl_options` / `hosts` / `host_authorization` を有効化、`bin/docker-entrypoint` から `db:prepare` を削除。Thruster (案 A / 案 B) は未決のまま `Dockerfile` / `Gemfile` / `bin/thrust` は変更していない ([未決事項](open-questions.md) #1)。切り替え差分は [初回デプロイ手順書](../ops/first-deploy.md) の 6 節にそのまま適用できる形で用意した
- **サーバ側は [初回デプロイ手順書](../ops/first-deploy.md) に従ってユーザーが実施する** (Dokku サーバへの接続が要るため): Thruster の実地判断、Dokku 側セットアップ (app 作成、postgres link、domains、letsencrypt、config:set)、初回デプロイ + `dokku run ... tsumikura:create_admin`、**DB の日次バックアップ設定 (後回しにしない)**。完了したら Thruster と PostgreSQL のメジャーバージョンの決定を [未決事項](open-questions.md) に反映する

**動作確認**: `https://tsumikura.example.com/up` が 200、ログインできる、`dokku logs` にジョブ supervisor の起動ログが出る、バックアップが 1 回取れている。
**Dokku の nginx が http → https に 301 リダイレクトすること**、**HSTS ヘッダが付くこと**、**ログイン後の `session_id` Cookie に `secure` (`force_ssl` が付ける) が付くこと**を確認する ([初回デプロイ手順書](../ops/first-deploy.md#9-動作確認チェックリスト))。

---

## Phase 6: マスタと品目

**ゴール**: カテゴリ・保管場所・店舗・品目の CRUD が動く。

**作業**

- `categories` / `storage_locations` / `stores` / `items` の migration とモデル (外部キーは `on_delete: :nullify`、
  `items` の check 制約は `current_quantity >= 0`)
- `ItemsController` (index/show/new/create/edit/update)、検索・フィルタ。
  **品目は物理削除しないので `destroy` は持たず**、`Items::ArchivesController` (アーカイブ / 復元) に分ける
- 各マスタの CRUD (`CategoriesController` / `StorageLocationsController` / `StoresController`)。
  並べ替えは JS 無しで動く「上へ / 下へ」(`Positioned` concern + `Categories::PositionsController` /
  `StorageLocations::PositionsController`)。削除は nullify なので、編集画面に「n 件の品目から外れます」を
  サーバ側で出す (`data-turbo-confirm` だけに頼らない)
- 品目フォームの予測設定 (`estimation_mode` / `manual_interval_days` / 閾値 / 最低在庫数 / 期限警告日数)。
  スマホで邪魔にならないよう `<details>` に畳む (Phase 10 の作業から前倒し。Phase 10 は表示・結線だけ)
- 下部タブの「品目」を有効化、メニューに「カテゴリ」「保管場所」「店舗」を追加

**TDD TODO**

```
Item モデル (spec/models/item_spec.rb)
- [x] Item は name が必須
- [x] Item は unit が必須で既定値は "個" (候補以外の自由入力も保存できる)
- [x] 入数の既定値は 1 以上・最低在庫数は 0 以上でなければ保存できない
- [x] manual_interval_days は 1 以上でなければ保存できない (0 や負ではペースを出せない)
- [x] estimation_mode が manual なら manual_interval_days は必須 (auto / none なら空でよい)
      (空のままだと予測が永久に unknown になり auto より悪くなる。仕様 02-forecast.md 8 節)
- [x] estimation_mode は auto / manual / none のいずれか (未知の値は検証エラー)
- [x] 購入推奨の日数は、そろそろ購入の日数より大きくできない (片方だけの上書きは既定値と比べる)
- [x] 閾値のエラー文には両方の実効値が入る
- [x] 閾値と期限警告日数は 0 以上でなければ保存できない
- [x] 数量系は MAX_QUANTITY (99,999)、日数系は MAX_DAYS (3,650) が上限
- [x] 4 バイト整数をはみ出す値でも例外にならず検証エラーになる (RangeError で 500 にしない)
- [x] 削除済みのカテゴリ / 保管場所の id (0 を含む) では保存できない (外部キー違反で 500 にしない)
- [x] name / unit / よみは前後の空白を落とす (全角スペースも)。よみが空白だけなら nil
- [x] よみはカタカナで入力してもひらがなで保存される
- [x] name 50 / name_reading 100 / unit 20 の長さ上限
- [x] 品目を作成すると current_quantity は 0 で、キャッシュ列は空
- [x] Item.active は archived_at が nil のものだけを返す / Item.archived はその逆
- [x] #archive! は行を消さず archived_at を打ち、二重呼び出しで日時を上書きしない
- [x] #restore! は archived_at を戻す
- [x] Item.search は名前でもよみでも当たる (当たらない品目も用意して確認)
- [x] Item.search は空文字・nil・空白 (全角スペースを含む) では絞り込まない
- [x] Item.search の % _ \ はワイルドカードではなくただの文字として扱う (sanitize_sql_like)
- [x] Item.search はカタカナの検索語でもひらがなのよみに当たる
- [x] Item.search は英字の大文字小文字を無視する (ILIKE。LIKE に変えたら落ちる)
- [x] Item.ordered はよみがあればよみ順、無ければ名前順
- [x] 在庫数を負にする UPDATE は DB の check 制約で弾かれる (キャッシュ再計算の最後の守り)
- [x] バリデーションを通らない品目でもアーカイブ・復元できる (閾値の既定を変えたあとなど)
- [x] 閾値が未設定なら config/tsumikura.yml の既定値を返す (effective_*)

マスタのモデル (spec/models/{category,storage_location,store}_spec.rb)
- [x] name は必須で一意
- [x] 作成順に position が振られ、.ordered はその順で返す
- [x] #move! :up / :down で 1 つ上 / 下と入れ替わる。端では false を返して何もしない
- [x] 未知の方向では何もしない / position が重複していても安定して動く
- [x] 並べ替えても updated_at を汚さない
- [x] 使用中のカテゴリを削除すると、その品目の category_id が nil になる (nullify、品目は消えない)
- [x] 使用中の保管場所も同様に nullify される
      (店舗を参照するのは lots なので、店舗の nullify は Phase 7 で検証する)
- [x] コールバックを通らない delete でも DB 側の on_delete: :nullify が効く
- [x] name は前後の空白 (全角スペースを含む) を落とす。落とさないと一意制約をすり抜ける
- [x] name は 50 文字まで
- [x] 店舗は position を持たないので名前順に並ぶ

品目の画面 (spec/requests/items_spec.rb, spec/requests/items/archives_spec.rb)
- [x] 品目一覧でカテゴリ絞り込みができる (絞られない品目も用意して確認)
- [x] 品目一覧で保管場所の絞り込みができる
- [x] 品目一覧で名前とよみで検索できる / 検索と絞り込みは同時に効く
- [x] 1 件も当たらないときはその旨を出す
- [x] アーカイブ済みは既定では出ない。状態を archived / all に切り替えると出る (知らない状態は既定に倒す)
- [x] 品目が増えても一覧のクエリ数は増えない (category / storage_location を includes)
- [x] 壊れた絞り込みパラメータ (配列・ハッシュ・数字でない id) は無視して既定に倒す
      (0 件にして「品目が無い」ように見せない)。存在しない id の絞り込みは効く
- [x] 4 バイト整数をはみ出す数量・削除済みのマスタ id を送っても 422 (500 にしない)
- [x] 品目詳細に在庫数・単位・分類・設定値 (最低在庫数・入数・予測モード・使用間隔・閾値・期限警告) が出る
- [x] 品目を作成・更新でき、予測設定も更新できる
- [x] キャッシュ列 (current_quantity / tracking_started_on / last_consumed_on) と archived_at は
      フォームから変更できない (mass assignment の遮断)
- [x] item キーが無ければ 400 (500 にしない)
- [x] 品目をアーカイブすると一覧に出ないが、詳細は開ける / 復元できる
- [x] 品目を物理削除するルート (DELETE /items/:id) は無い

マスタの画面 (spec/requests/{categories,storage_locations,stores}_spec.rb)
- [x] 一覧・追加・編集ができる。名前が空 / 重複なら追加できない
- [x] 追加したマスタは末尾に並ぶ
- [x] position はフォームからは変更できない (並べ替えは PositionsController の担当)
- [x] 「上へ / 下へ」で並べ替えできる。端や未知の方向では並びが変わらない
- [x] 削除すると品目は消えず、カテゴリ / 保管場所だけが外れる (アーカイブ済みの品目からも外れる)
- [x] 削除後に「n 件の品目から外れました」と知らせる
- [x] 削除前に「n 件の品目から外れます」を編集画面に出す (rack_test でも検証できる)
- [x] 店舗はメモつきで追加・編集・削除できる

認可 (spec/requests/authorization_spec.rb)
- [x] 表は品目とマスタの全ルートを網羅している (ルーティングと突き合わせて足し忘れを検出)
- [x] 未ログインでは品目とマスタの全アクション (28 種) がログイン画面にリダイレクトされる (表駆動)
- [x] 未ログインで全アクションを叩いてもレコードは増えず、既存のレコードも変わらない
- [x] ログイン済みの一般ユーザーは全アクションが拒否されない (品目とマスタは管理者限定ではない)

画面 (spec/system/{items,masters,navigation}_spec.rb)
- [x] 品目タブから品目一覧に行ける / 未実装のタブは買い物・記録の 2 つだけになる
- [x] 品目の詳細・追加・編集でも品目タブがハイライトされる (品目以外のページでは付かない)
- [x] メニューからカテゴリ・保管場所・店舗に行ける
- [x] 品目を登録して詳細を見られる / 名前が空ならエラーを出してフォームに戻る
- [x] 予測設定は details に畳まれていて (開閉の印つき)、summary を開いて設定できる
- [x] 一覧で検索・カテゴリ絞り込みができる / 1 件も当たらないときの表示が出る
- [x] アーカイブすると一覧から外れ、詳細から戻せる。物理削除のボタンは無い
- [x] マスタを追加・並べ替え・削除できる (端のボタンは disabled)
- [x] 並べ替えボタンのアクセシブルネームに行の名前が入る
- [x] 削除前に外れる品目の件数が画面に出る
```

**動作確認**: 品目を 5 件ほど登録し、カテゴリで絞り込める。

**次フェーズの前にやる整理 (別コミット)**

- [x] 整理: Phase 4 のビュー (`app/views/admin/`, `app/views/accounts/`, `app/views/sessions/`) を
      Phase 6 で作ったフォームヘルパー (`field_classes` / `label_classes` / `primary_button_classes` など) と
      `app/views/application/_form_errors.html.erb` に寄せる

---

## Phase 7: 在庫台帳と購入

**ゴール**: 購入を入力すると在庫が増え、ロット一覧に表示される。初期在庫も入れられる。

**作業**

- `lots` / `stock_movements` の migration とモデル
  (`stock_movements.usage_record_id` / `stock_take_entry_id` は参照先が Phase 8 / 9 なので列と index だけ作り、
  外部キーはそれぞれのフェーズで `add_foreign_key` する)
- `Stock::Recalculator` / `Stock::RecordPurchase` / `Stock::ReviseLot` / `Stock::DeleteLot` / `Stock::Verifier`
- `LotsController#new/create/edit/update/destroy`
- 「入数 × パック数 / 直接入力」トグルの Stimulus コントローラ (JS 無しでも動く)
- 品目詳細のロット一覧 (期限順・残数・期限・購入日・店舗・単価・平均単価) と「購入を記録」
- 店舗の nullify の検証 (Phase 6 から先送り) と、編集画面の削除警告に件数を出す
- `lib/tasks/stock.rake` に `stock:verify` / `stock:recalculate`

**TDD TODO**

```
台帳のモデル (spec/models/stock_movement_spec.rb, spec/models/lot_spec.rb)
- [x] StockMovement は quantity が 0 では保存できない (DB の check 制約でも弾かれる)
- [x] StockMovement の符号は kind と対応する (purchase は正、usage / disposal は負)
- [x] StockMovement の item_id はロットの品目と一致していなければならない (非正規化のずれ防止)
- [x] 未来の日付の記録は保存できない (今日は可、明日は不可)
- [x] Lot の数量は 1 以上 (DB の check 制約でも弾かれる)、残数を負にする UPDATE も弾かれる
- [x] 入数 × パック数がそろっていればその積、片方だけなら直接入力の数量を使う
- [x] 数量・入数・パック数・金額には上限があり、4 バイト整数をはみ出しても検証エラーになる
      (入数 × パック数の積が上限を超える場合も)
- [x] 削除済みの店舗 id では保存できない (外部キー違反で 500 にしない)
- [x] 単価は 税込合計 ÷ 数量 (四捨五入)、平均単価は価格のあるロットだけで計算する
- [x] 使用・廃棄の記録が紐づくロットは削除できない。入庫だけのロットは削除できる
- [x] 既に使われた数より小さい数量には編集できない
- [x] FEFO の並び (期限が近い順 → 期限なし → 期限切れは最後、同じ期限なら購入が古い順)
- [x] 記録者のユーザーは物理削除できない (外部キーで止まる。restrict は RestrictViolation)
- [x] 編集では「書き換えたほう」が勝つ (数量だけ → 直接入力、入数・パック数 → 積、
      どちらも変えなければ積のまま)。検証エラーでは入数の入力を消さない
- [x] DB の check 制約: 入数とパック数は両方あるか両方 NULL、積が数量と一致する
- [x] DB の check 制約: 符号と種別の対応、廃棄理由は廃棄の記録だけ
- [x] ロットと違う品目を指す記録は複合外部キー (lot_id, item_id) で弾かれる (UPDATE も INSERT も)
- [x] 棚卸のマイナス差分 (負の調整) が紐づくロットも削除できない。プラスの調整だけなら削除できる
- [x] 消費済みのロットを持つ品目を削除しても記録が半端に残らない (movement を先に消す)
- [x] 0 時台 (JST) でも今日の購入は保存できる (CI の UTC で Date.today の混入を検出する)

Stock::Recalculator (spec/models/stock/recalculator_spec.rb)
- [x] ロットの残数は movements の総和になる
- [x] 品目の在庫数は全ロットの残数の合計になる
- [x] キャッシュがずれていても (多すぎても少なすぎても) 台帳から正しい値に戻す
- [x] 残 0 のロットには depleted_at を打ち、残が戻ったら消す。再計算で日時は上書きしない
- [x] item.tracking_started_on は最も古い StockMovement の occurred_on になる
      (あとから古い記録を足すとより古い日に戻る)
- [x] item.last_consumed_on は使用と棚卸のマイナス差分の最新日 (廃棄と入庫は数えない)
- [x] 他の品目のロット・在庫には触らない
- [x] キャッシュの書き戻しで items.updated_at は汚さない

Stock::RecordPurchase / ReviseLot / DeleteLot (spec/models/stock/*_spec.rb)
- [x] 購入を記録すると Lot が 1 件と StockMovement(purchase, +12) が 1 件作られる
- [x] 購入を記録すると lot.remaining_quantity が 12 になる
- [x] 購入を記録すると item.current_quantity が 12 になる
- [x] 2 回購入すると item.current_quantity は合計になる
- [x] 入数 12 × パック数 2 で数量 24 の Lot が作られる
- [x] 初期在庫 (kind: initial) も同じ経路を通り、movement の kind は purchase になる
- [x] 未来の日付の購入は保存できず、Lot も movement も作られない
- [x] 購入記録の数量を編集すると在庫が再計算され、入庫の movement も直る
- [x] 購入記録を削除すると在庫が元に戻る。使用済みのロットは削除できない
- [x] キャッシュ列・記録者・品目・由来はサービスに渡しても変わらない
- [x] 途中で例外が起きたら Lot も movement も残らない (同一トランザクション)
- [x] 各サービスは最初の書き込みより前に品目を行ロックする (FOR UPDATE の位置を SQL で確認)
- [x] ロックの前に読んだ古いロットを渡しても、ロットと入庫の記録がずれない (ロック後に reload)
- [x] 別の画面で先に削除されていたら RecordNotFound になる (「削除しました」と嘘をつかない)
- [x] 入庫の記録が無いロットの編集は例外になる (黙って直さない)

購入の画面 (spec/requests/lots_spec.rb)
- [x] 入力フォームの入数の初期値は item.default_pack_size、購入日の初期値は今日
- [x] 期限日は tracks_expiry の品目にだけ出る
- [x] JS が無いときのために数量の入力欄が 3 つとも出ている
- [x] 入数・パック数・直接入力をすべて送ると入数 × パック数が優先される (JS 無しの経路)
- [x] 店舗・金額・期限・メモも記録できる
- [x] 種別に adjustment や知らない値を送っても購入として記録される
- [x] アーカイブ済みの品目にも記録できる
- [x] 壊れた入力 (未来日・空の数量・上限超え・削除済みの店舗 id) は 422 (500 にしない)
- [x] lot キーが無ければ 400 (500 にしない)
- [x] 残数 / 使い切った日時 / 記録者 / 品目 / 種別はフォームから変更できない (mass assignment の遮断)
- [x] 数量を編集すると在庫が再計算され、使われた数より小さくすると 422
- [x] 削除すると在庫が戻る。使用の記録が紐づくロットは削除できず、その旨を知らせる
- [x] 入数 × パック数のロットは、数量だけ送れば直接入力が勝ち、入数を送れば積が勝つ
- [x] 購入日が空 / 壊れた日付でも 422 (編集画面の再描画で 500 にしない)
- [x] 調整ロットの編集・更新・削除は 404 (画面からは購入と初期在庫のロットだけ)

品目の画面 (spec/requests/items_spec.rb)
- [x] 品目詳細のロット一覧に残数・期限・購入日・店舗・単価が出る
- [x] 在庫のあるロットは期限が近い順に並ぶ
- [x] 残 0 のロットは畳まれた一覧に入り、新しいものから決まった件数だけ出す
- [x] 単価の平均は価格のある直近 5 件だけで計算する。10 円未満の単価は小数 1 桁で出す
- [x] ロットが増えても品目詳細のクエリ数は増えない (store を includes)
- [x] 品目一覧に在庫数が出る。在庫のある品目が増えてもクエリ数は増えない (キャッシュ列)

店舗の nullify (spec/models/store_spec.rb, spec/requests/stores_spec.rb)
- [x] 店舗を削除しても購入の記録は消えず、店舗だけが外れる (在庫数も変わらない)
- [x] コールバックを通らない delete でも DB 側の on_delete: :nullify が効く
- [x] 削除後に「n 件の購入の記録から外れました」と知らせ、編集画面に「n 件から外れます」を出す

認可 (spec/requests/authorization_spec.rb)
- [x] 表に購入の全ルート (5 種) を足し、未ログインではすべてログイン画面にリダイレクトされる
- [x] 未ログインで叩いても Lot / StockMovement は増えず、既存のロットも変わらない

画面 (spec/system/lots_spec.rb)
- [x] JS が無くても品目詳細から購入を記録でき、在庫とロット一覧が増える
- [x] JS が無いときは切り替えボタンを出さず、数量の入力欄を 3 つとも出す
- [x] 入数とパック数を空にすれば直接入力の数量で記録できる
- [x] 未来の日付はサーバ側で弾かれ、フォームに戻る
- [x] 記録した購入を編集・削除すると在庫が追随する
- [ ] 実ブラウザでは入力方法を切り替えられ、使わない側の欄は送られない
      (js: true。ローカルには Chrome が無く skip されるので、CI で初めて実行される)

rake タスク (spec/tasks/stock_spec.rb)
- [x] stock:verify はキャッシュと台帳の差異を検出する (差異があれば異常終了)
- [x] stock:verify は差異が無ければ正常終了し、ずれていない品目は出力に並ばない
- [x] stock:verify は使い切った日時のずれ、入庫の記録とのずれ (数量・日付・記録なし)、
      ロットと違う品目を指す記録も検出する
- [x] stock:recalculate は全品目のキャッシュを直し、そのあと stock:verify が通る
- [x] stock:recalculate は直せない品目があっても他は直し、一覧を出して異常終了する
```

**検出範囲 (`stock:verify`)**: `lots.remaining_quantity` / `lots.depleted_at` /
`items.current_quantity` / `tracking_started_on` / `last_consumed_on` のキャッシュのずれに加えて、
**再計算では直らないずれ** (入庫 movement とロットの数量・日付、入庫 movement が無いロット、
`stock_movements.item_id` とロットのずれ) も報告する。

**動作確認**: 購入を 2 回入れて在庫が合計になる。`stock:verify` が差異 0 を報告する。

---

## Phase 8: 使用記録と用途

**ゴール**: 品目一覧の「使った」ボタン 1 タップで在庫が減り、取り消せる。用途つきの記録もできる。

**作業**

- `usage_records` / `item_purposes` の migration とモデル (`stock_movements.usage_record_id` に `add_foreign_key`)
- `Stock::Allocator` (FEFO + 在庫不足時の自動調整ロット) と `Stock::UsageMovements` (movement の作成・片づけ)
- `Stock::RecordUsage` / `Stock::ReviseUsage` / `Stock::DeleteMovement` (いずれも `call!` つき)
- `UsageRecordsController`、`Items::QuickUsesController` (Turbo Stream + 取り消しトースト)。
  「1 リソース = 1 コントローラ」に合わせて `ItemsController#quick_use` にはしない
- `ItemPurposesController` + `ItemPurposes::PositionsController` / `ItemPurposes::ArchivesController`。
  `Positioned` を品目ごとのスコープで使えるよう `positioned_siblings` を足す
- 品目一覧・詳細の「使った」、品目詳細の用途一覧 (最終交換日・交換周期) と「最近の記録」
- トーストの自動消去・数量の +/−・日付の「今日 / 昨日」の Stimulus (いずれも JS 無しで動く)
- `stock:verify` に使用記録と movement のずれの検査を追加
- ロットの削除・数量編集の制限 (Phase 7 のガード) が実際の使用記録で効くことの確認

**TDD TODO**

```
Stock::Allocator (spec/models/stock/allocator_spec.rb)
- [x] Stock::Allocator は期限が近いロットから引き当てる
- [x] Stock::Allocator は期限 nil のロットを期限つきロットの後に引き当てる
- [x] Stock::Allocator は期限切れロットを最後に引き当てる (今日が期限ならまだ期限切れではない)
- [x] 期限が同じなら購入が古いロットから引き当てる
- [x] 残 0 のロットは引き当てに使わない / 他の品目のロットには触らない
- [x] 在庫 5 のロットに対して 3 使うと、そのロットから 3 だけ引かれる
- [x] ロット A に 2・ロット B に 5 あるとき 4 使うと、A から 2・B から 2 に分割される
- [x] 在庫 2 に対して 3 使うと kind: adjustment のロットが 1 件作られ、不足 1 が補われる
- [x] 補填の調整ロットは期限も価格も持たず、日付は使用日になる
- [x] ロットを手動指定すると、そのロットから先に引く (足りない分は FEFO → 補填の順)
- [x] 先読み済みのロットではなく、その場で読んだ残数で引き当てる

使用記録 (spec/models/stock/{record_usage,revise_usage,delete_movement}_spec.rb)
- [x] 分割されても UsageRecord は 1 件、StockMovement は 2 件
- [x] 使用記録を作ると item.last_consumed_on が used_on になる
- [x] 過去日 (3 日前) の使用記録を作っても現在庫は正しく減る
- [x] 未来の日付の使用記録は保存できない (movement も調整ロットも作られない)
- [x] 補填の入庫 (正の adjustment) は消費に数えない
- [x] 最新の使用記録を削除すると item.last_consumed_on は 1 つ前の消費日に戻る
- [x] 使用記録を削除すると在庫が戻り、分割された StockMovement もすべて消える
- [x] 使用記録を編集すると movement を作り直し、数量・日付・用途・ロットが追随する
- [x] 各サービスは最初の書き込みより前に品目を行ロックする (FOR UPDATE の位置を SQL で確認)
- [x] ロックの前に読んだ古い在庫では引き当てない / 古い値で上書きしない
- [x] 別の画面で先に削除されていたら RecordNotFound になる
- [x] 用途を指定した使用記録は item_purpose_id を持つ (他の品目の用途・ロットは指定できない)
- [x] 使用済みのロットは削除できない / 既に使われた数より小さい数量には編集できない
      (Phase 7 のガードが実際の使用記録で効いている)

用途 (spec/models/item_purpose_spec.rb)
- [x] ItemPurpose#replacement_interval_days は used_on の差分の中央値を返す
      (平均ではない / 偶数個なら中央 2 つの平均 / 同じ日の記録は 1 回と数える)
- [x] 使用記録が 1 件の用途は interval を返さず、最終使用日だけを返す
- [x] name は品目の中で一意。position は品目ごとに 1 から振られ、並べ替えも品目の中で閉じる
- [x] アーカイブ済みの用途は並べ替えの対象にならず、解除すると末尾に並ぶ
      (採番はアーカイブ済みも含めた末尾から。position が重ならない)
- [x] 使用記録がある用途は削除できず、アーカイブで一覧から外す (外部キーも restrict)

引き当て直しと既定値 (Fable の査読を反映)
- [x] メモ・用途だけの編集ではロット別の残数が変わらない (元のロットを優先して引き直す)
- [x] 手動で指定した記録を数量だけ編集しても、指定したロットが優先される
- [x] 自分が引いていた分を戻してから引き当てる (途中の再計算を省くと要らない補填が出る)
- [x] 在庫を超えて増やすと補填が増え、調整ロットは 1 件のまま作り直される
- [x] 数量を空で送ると、選んだ用途の既定数量 (用途なしなら 1) で補う。0 は 422 のまま
- [x] 指定したロットが使い切られていても記録は成功し、その旨を知らせる
      (他の品目のロットは今までどおり 422)
- [x] usage_records ⇔ stock_movements / item_purposes の item_id は複合外部キーで守る
- [x] stock:verify は「使用記録に紐づかない使用の記録」「使用記録に紐づく movement の種別」
      「補填の調整ロットの残り」「使用記録と違う品目を指す記録」も検出する

画面 (spec/requests/{usage_records,item_purposes,items}_spec.rb,
      spec/requests/items/quick_uses_spec.rb, spec/system/usage_records_spec.rb)
- [x] ワンタップ使用は数量 1・今日・FEFO・用途なしで記録される
- [x] Turbo Stream で一覧の行と品目詳細を更新し、取り消し付きトーストを足す
- [x] JS が無くても記録でき、押した画面に戻って flash のトーストに取り消しが出る
- [x] 在庫不足で補填したときは「n ロール を調整しました」を伝える
- [x] 用途を管理する品目の一覧の「使った」は、用途を選べるフォームへのリンクになる
- [x] 品目詳細に用途一覧 (最終交換日・交換周期) と最近の記録 (使用と購入・編集 / 削除) が出る
- [x] 用途の CRUD・並べ替え・アーカイブができ、他の品目の用途は触れない (404)
- [x] 壊れた入力 (未来日・0・上限超え・他品目の用途 / ロット) は 422、キー無しは 400 (500 にしない)
- [x] 品目・記録者・並び順・アーカイブはフォームから変更できない (mass assignment の遮断)
- [x] アーカイブ済みの品目には「使った」ボタンを出さない
- [x] すでに取り消された記録の「取り消し」は 404 にせず、その旨を知らせて戻る
- [x] 編集画面 (検証エラーでの再描画を含む) から削除したときは品目詳細に戻る
- [x] 編集フォームのロット選択の既定は「変更しない」。アーカイブ済みの用途も選択肢に残る
- [x] 表に使用記録と用途の全ルート (15 種) を足し、未ログインではログイン画面にリダイレクトされる
- [ ] 実ブラウザではワンタップでトーストが出て 8 秒で消え、取り消しで在庫が戻る
      (js: true。ローカルには Chrome が無く skip されるので、CI で初めて実行される)
- [ ] 実ブラウザでは数量の +/− と日付の「昨日」ボタンが使える
      (js: true。ローカルには Chrome が無く skip されるので、CI で初めて実行される)

Phase 7 からの申し送り (docs/spec/01-domain-model.md 5 節)
- [x] usage_records を作ったら stock_movements.usage_record_id に add_foreign_key する
- [x] Stock::Allocator は item.lock! の「あと」に lots.available.fefo を読む
      (ロックの前に読んだロットで引き当てない)
- [x] 在庫不足の補填で作った調整ロットは、使用記録の削除・編集で補填の +movement ごと消える
      (+movement にも usage_record_id を持たせ、movement が無くなった調整ロットは削除する)
- [x] 入れ子で呼ぶサービスには call! (例外を上げる) を用意する
      (内側の ActiveRecord::Rollback は内側の transaction に握りつぶされ、外側はコミットされる)
- [x] stock:verify に「usage_record の quantity == 紐づく movements の合計」を足す
      (補填の入庫は数えない。used_on と occurred_on のずれも検出する)
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

Phase 7 / 8 からの申し送り (docs/spec/01-domain-model.md 5 節)
- [ ] stock_take_entries を作ったら stock_movements.stock_take_entry_id に add_foreign_key する
      (usage_record_id と同じく on_delete は付けない)
- [ ] 棚卸の確定で複数の品目をロックするときは id の昇順で lock! する (デッドロック防止)
- [ ] 棚卸のマイナス差分が紐づくロットは削除できない (Phase 7 のガードが効いていること)
- [ ] 既存ロットに正の adjustment を付ける設計にするなら、Stock::ReviseLot の
      「入庫 = 最初の正の movement」という前提と数量の検証を作り直す
- [ ] 棚卸のプラス差分で作る調整ロットには、使用記録に紐づかない入庫 movement を必ず持たせる
      (持たせないと Stock::UsageMovements#discard! が「空の調整ロット」として消してしまう)
- [ ] 棚卸のマイナス差分の引き当ても Stock::Allocator を使う。ただし Allocator は不足分を
      必ず補填する (調整ロットを作る) ので、compensate: false のオプションが要る
- [ ] 廃棄の削除を Stock::DeleteMovement に足すときは、引数の型で分岐せず
      共通部分 (Stock::UsageMovements) を一般化するか別サービスに分ける
- [ ] flash[:undo_usage_record_id] とトーストの「取り消し」は使用記録専用。
      廃棄の取り消しにも使うなら undo_path を渡す形に一般化する
- [ ] 使用記録に紐づかない kind: usage の movement を作らない (stock:verify が検出する)
- [ ] 判断 1 の「直近の棚卸日より前の日付です」の警告を、使用記録と購入のフォームに足す
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
- 品目編集の予測設定 (`estimation_mode` / `manual_interval_days` / 閾値 / 最低在庫数 / 期限警告日数) は
  Phase 6 で作成済み。ここでは予測結果 (在庫切れ予測日・ペース・判定理由) の表示だけを足す

**TDD TODO**

```
- [ ] SnapshotBuilder は消費の定義に StockMovement.consumption スコープを使う
      (「使用と負の調整」の定義を Stock::Recalculator と 1 か所にそろえる)
- [ ] u (usage_records.quantity の中央値) と消費量 (stock_movements) は別のテーブルから数える。
      一致は rake stock:verify の「使用の数量」の検査が前提 (Phase 8 からの申し送り)
- [ ] 在庫不足を補填した使用も消費に数える (補填の入庫は正の adjustment なので分子に入らない)
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
- [ ] SnapshotBuilder は estimation_mode を Symbol (:auto / :manual / :none) で Snapshot に渡す
      (Forecast::Pace は文字列や整数を ArgumentError にする)
- [ ] BatchForecaster の結果は、各品目を ItemForecaster で個別に判定した結果と一致する
- [ ] アーカイブ済みの品目は BatchForecaster の対象にもダッシュボードにも出ない
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
| `config/application.rb` | `config.action_cable.mount_path = nil` (Action Cable を使わないので `/cable` を生やさない) | 4 |

`Gemfile` は `gem "json", "< 3"` で固定している。json 3 が `JSON.parse` のオプションをキーワード引数でしか受けず、ハッシュを位置引数で渡す ActiveSupport 8.1.3.1 と噛み合わないため (Phase 4 で 70 件の spec が落ちた)。**Rails を更新したらこの行を外して `bin/rspec` を流し、通るなら固定を解除する。**

## 付録 B: 削除するファイル

`config/deploy.yml`、`.kamal/`、`bin/kamal`、`db/queue_schema.rb`、`db/cache_schema.rb`、`db/cable_schema.rb`、`test/` 一式、`app/controllers/passwords_controller.rb` (生成後)、`app/mailers/passwords_mailer.rb` (生成後)、`app/views/passwords/` (生成後)、`app/views/passwords_mailer/`、`app/channels/` (生成後。Action Cable を使わないため)。
Thruster を外すと決めた場合は `bin/thrust` も削除する (Phase 5)。

## 付録 C: 新規作成するファイル (設定系)

`mise.toml`、`compose.yaml`、`app.json`、`config/tsumikura.yml`、`config/initializers/webauthn.rb`、`config/initializers/web_push.rb`、`lib/tasks/tsumikura.rake`、`lib/tasks/stock.rake`。
