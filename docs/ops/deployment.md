# デプロイ (Dokku)

[初回デプロイ手順](first-deploy.md) / [開発環境](development.md) / [概要](../spec/00-overview.md) / [通知](../spec/04-notifications.md) / [未決事項](../plan/open-questions.md)

既存の Dokku サーバに同居させる。Dockerfile デプロイ + 単一 `DATABASE_URL` + `SOLID_QUEUE_IN_PUMA` で、**アプリのコンテナは 1 つ**にする。Kamal は使わないので関連ファイルを削除する。

## 1. 単一 DB 化

`rails new` 直後の `config/database.yml` の production は `primary` / `cache` / `queue` / `cable` の 4 接続になっている。dokku-postgres が渡す単一の `DATABASE_URL` に寄せる。

### 1.1 Solid Cable を削除する (確定)

リアルタイム同期は不要と決めたので、**`solid_cable` は削除する**。

- `Gemfile` から `gem "solid_cable"` を削除し、`db/cable_schema.rb` を削除する。
- `config/cable.yml` は production も `adapter: async` にする (未使用のまま残す形でもよい)。
- 認証ジェネレータが作る `app/channels/` は削除する (生成される `Connection#set_current_user` は `deactivated_at` を見ないので、残すと無効化したユーザーが WebSocket で認証できてしまう)。
- **`config/application.rb` に `config.action_cable.mount_path = nil` を置く。** `app/channels/` を消しても `ActionCable::Engine` は `/cable` をマウントし、素の `Connection::Base` が未認証の WebSocket を受け付けるため。
- 画面の即時反映は、操作したリクエストへの Turbo Stream レスポンスで行う。他のデバイスの画面が自動更新されないのは仕様とする。
- 補足: solid_cable は既定で `polling_interval: 0.1.seconds` の DB ポーリングを行う。他のアプリと共有する Postgres に常時その負荷を掛けるのは、家庭用アプリには割に合わない。
- 将来リアルタイム配信が必要になったら、solid_cable を primary DB に同居させて `polling_interval` を緩める形で戻せる。

### 1.2 Solid Queue / Solid Cache のテーブルを通常の migration に取り込む

- `db/queue_schema.rb` (160 行) と `db/cache_schema.rb` の中身を `db/migrate/` の migration に書き写す。
- 変換時の注意:
  - `ActiveRecord::Schema[7.1].define(version: 1) do ... end` (cache 側は `[7.2]`) → `class CreateSolidQueueTables < ActiveRecord::Migration[8.1]` + `def change`
  - **`create_table ..., force: :cascade` の `force: :cascade` を必ず削除する** (既存テーブルを DROP してしまう)
  - `add_foreign_key` (solid_queue は FK を持つ) はそのまま移す
  - solid_cache の `t.binary "value", limit: 536870912` は PostgreSQL では `bytea` になる。そのままで動く
- 元の `db/queue_schema.rb` / `db/cache_schema.rb` は削除する。
- **採用しない案**: `migrations_paths` を残したまま同じ DB を指す構成。同一 DB に対して複数の `schema_migrations` 管理が走り、`db:prepare` が競合するので危険。

### 1.3 gem アップデート時の運用 (`solid_queue:update`)

Solid Queue / Solid Cache を上げると `bin/rails solid_queue:update` が `db/queue_schema.rb` を再生成し、単一 DB 構成と食い違う。手順を固定する。

```bash
mise x -- bundle update solid_queue
mise x -- bin/rails solid_queue:update      # db/queue_schema.rb が再生成される
git diff db/queue_schema.rb                 # 差分を確認する
# 差分の内容だけを新しい migration (db/migrate/) に手で書き写す
git checkout -- db/queue_schema.rb || rm -f db/queue_schema.rb   # 生成物は残さない
mise x -- bin/rails db:migrate
```

### 1.4 設定ファイルの変更

```yaml
# config/database.yml
production:
  <<: *default
  # DATABASE_URL が自動でマージされる (dokku postgres:link が設定する)
```

- `config/cache.yml` の production から `database: cache` を削除する (primary を使う)。
- `config/environments/production.rb` から `config.solid_queue.connects_to = { database: { writing: :queue } }` を削除する。

## 2. ジョブの実行 (SOLID_QUEUE_IN_PUMA)

`config/puma.rb` は既に `plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]` を持っているので変更不要。

```bash
dokku config:set tsumikura SOLID_QUEUE_IN_PUMA=1 WEB_CONCURRENCY=0 RAILS_MAX_THREADS=3
```

- `WEB_CONCURRENCY=0` で Puma を single mode (ワーカープロセスなし) にする。家庭用の負荷ではワーカーを分ける必要がなく、Puma と Solid Queue の supervisor を合わせてもメモリが小さく済む。
- コンテナは 1 つだけ動かす (`dokku ps:scale tsumikura web=1` のまま)。web を複数に増やすと Solid Queue の supervisor も複数になる。
- `config/queue.yml` の production は `threads: 3, processes: 1` のままでよい。DB 負荷が気になれば `polling_interval` を 1 → 5 に。
- 日次ダイジェストは `config/recurring.yml` に定義する ([通知](../spec/04-notifications.md))。
- **DB 接続プール**: Solid Queue の supervisor は Puma とは別プロセスで動くため、`RAILS_MAX_THREADS` (Puma のスレッド数) の分だけでは `config/queue.yml` の worker (`threads: 3`) + dispatcher の接続要求を満たせないことがある。`config/database.yml` の `max_connections` は既定で `RAILS_MAX_THREADS + 2` にしている (`DB_POOL` で明示上書きできる)。
- **ゼロダウンタイムデプロイ中の重複実行**: 新旧コンテナが一時的に並走しても、Solid Queue の recurring は `solid_queue_recurring_executions` の unique index (`task_key`, `run_at`) で重複排除されるため、日次ダイジェストが二重送信されることはない。

## 3. Dockerfile

| 項目 | 現状 | 変更 | 理由 |
|---|---|---|---|
| `BUNDLE_WITHOUT` | `"development"` | `"development:test"` | RSpec / Capybara / Selenium を本番イメージに入れない |
| Thruster | `CMD ["./bin/thrust", "./bin/rails", "server"]` / `EXPOSE 80` | **変更しない (案 B で確定。3.1 節)** | 初回デプロイでそのまま動いた |

`bin/docker-entrypoint` の `db:prepare` は削除し、マイグレーションは `app.json` の predeploy に一本化する (4 節)。

### 3.1 Thruster をどうするか (決定済み: 残す)

> **決定 (2026-09-21)**: **案 B (Thruster を残す。`Dockerfile` / `Gemfile` / `bin/thrust` は変更なし) で確定。**
> Dokku への初回デプロイで `Dockerfile` を一切変えずにそのまま動いた (`bind: permission denied` も 502 も出なかった)。
> `ports:set` の明示も要らなかった。以下の検討内容と案 A の切り替え手順は**参考 (使わなかった)** として残す。
> 将来 Docker が古い環境へ移すときや 502 が出たときは、案 A に倒せる。

査読 (Dokku / Thruster のソースと公式ドキュメントで確認): Dockerfile デプロイで Dokku はコンテナに `PORT` 環境変数を注入する (`EXPOSE 80` なら `PORT=80`)。一方 Thruster は自分の待ち受けポートには `PORT` を使わず `HTTP_PORT` (既定 80) を見て、子プロセス (Puma) を起動するときは `PORT` を `TARGET_PORT` (既定 3000) で上書きして渡す。したがって Dokku が注入する `PORT` と Thruster / Puma の間でポートの取り合いは起きにくい。残る懸念は非 root (uid 1000) での 80 番への bind だけで、Docker 20.10 以降のブリッジネットワークでは `ip_unprivileged_port_start` の既定が 0 のため通常は問題ない (失敗時の症状は `listen tcp :80: bind: permission denied`)。

**実地の結果: 案 B (現状の Dockerfile のまま、変更なし) が素直に動いたので、これで確定した。** 具体的な確認手順は [初回デプロイ手順書](first-deploy.md#6-thruster-の判断-決定済み-案-b) を参照。

**案 A: Thruster を外して Puma 直起動 (参考。使わなかった)**

```dockerfile
EXPOSE 3000
CMD ["./bin/rails", "server"]
```

- `Gemfile` から `gem "thruster"` を削除し、`bin/thrust` も削除する。
- Dockerfile デプロイでは `EXPOSE` からの自動検出マッピングが `http:3000:3000` になり、外部の 80/443 番への対応が無くなる (letsencrypt の HTTP-01 チャレンジも失敗する)。**`dokku ports:set tsumikura http:80:3000` を明示的に実行する必要がある。**
- 前段に Dokku の nginx がいるので、Thruster の圧縮・キャッシュ・X-Sendfile の価値は限定的。

**案 B: Thruster を残す (現状の Dockerfile のまま) — 採用**

- `EXPOSE 80` のまま。Dockerfile デプロイでは `EXPOSE` から `Ports map detected: http:80:80` が自動検出されるので、`ports:set` による明示設定は不要 (`dokku ports:report` で確認する)。**実地でもこのとおりだった。**
- 静的アセットの gzip / brotli 配信と X-Sendfile が使える。将来 Dokku 以外へ移すときに構成を変えずに済む。

**判断材料**

| 観点 | 案 A | 案 B |
|---|---|---|
| ポート設定の事故 | `ports:set` を手動で追加する必要がある | 自動検出でそのまま動く可能性が高い |
| 静的配信の性能 | Rails (Propshaft) が返す。家庭用の同時 1〜5 人なら十分 | Thruster が圧縮・キャッシュする |
| 生成物からの乖離 | `rails new` の既定から外れる | 既定のまま |
| 切り戻し | いつでも戻せる (Gemfile と Dockerfile の数行) | 同左 |

初回デプロイで案 B が素直に動いたのでそのまま残した (2026-09-21)。[未決事項](../plan/open-questions.md) #1 も決定済みに移してある。

## 4. `app.json`

リポジトリルートに新規作成する。

```json
{
  "name": "tsumikura",
  "description": "家族でつなぐ、暮らしのストック",
  "scripts": {
    "dokku": {
      "predeploy": "bundle exec rails db:prepare"
    }
  },
  "healthchecks": {
    "web": [
      {
        "type": "startup",
        "name": "app boot check",
        "description": "/up が 200 を返すことを確認",
        "path": "/up",
        "attempts": 12,
        "wait": 5,
        "timeout": 10
      }
    ]
  }
}
```

- `predeploy` は新しいイメージで、トラフィックを流す前に実行される。`db:prepare` (create + schema load + migrate) の置き場所として適切。Dockerfile デプロイでも実行される (査読で確認済み)。
- `predeploy` は `Dockerfile` の `ENTRYPOINT` (`bin/docker-entrypoint`) 経由で、非 root ユーザー (uid 1000)・作業ディレクトリ `/rails` で実行される。`ENTRYPOINT` は引数をそのまま `exec` するだけなので、predeploy のコマンド文字列に `&&` や `|` などのシェル構文は使えない (`bundle exec rails db:prepare` は単一コマンドなので問題ない)。
- `postdeploy` は使わない。初期管理者の作成は冪等性と可視性のために手動実行とする。
- ヘルスチェックの `/up` は Rails 既定の `rails/health#show` をそのまま使う。predeploy の実行ログは `dokku logs` ではなく `git push` の出力に出る (`Executing predeploy task from app.json ...` という行)。デプロイ自体が失敗した場合は `dokku logs:failed tsumikura` で直前の失敗したビルドのログを確認する。

## 5. SSL とホスト認可

`config/environments/production.rb` で以下を有効にする。

```ruby
config.assume_ssl = true          # nginx が X-Forwarded-Proto を付ける
config.force_ssl  = true          # HSTS + secure cookie
config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

config.hosts = [ ENV["APP_HOST"].presence || "localhost" ]  # 空文字での事故防止に .presence を使う
config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
```

- Dokku の nginx が TLS を終端し、アプリには http で到達する。`assume_ssl = true` がないと `force_ssl` が無限リダイレクトを起こす。`assume_ssl` が有効な間、http → https の実際のリダイレクトは (アプリではなく) Dokku の nginx が証明書発行後に行う。
- **`/up` をホスト認可から除外する**のが重要。Dokku の内部ヘルスチェックはコンテナに直接 http でアクセスするため、除外しないとデプロイがヘルスチェックで失敗する (`ssl_options` の `/up` 除外は `assume_ssl` が有効な間は実際には発火しない保険で、`host_authorization` の `/up` 除外が実質的に効く)。
- `dokku-letsencrypt` の ACME チャレンジ (`/.well-known/acme-challenge`) は nginx が直接応答するのでアプリには届かない。`force_ssl` を先に入れても証明書の発行は成功する。
- `force_ssl` の既定は HSTS に `includeSubDomains` を含める。`APP_HOST` がサブドメイン (`tsumikura.example.com` のような形) であれば、同じサーバの他アプリ (兄弟サブドメイン) には影響しない。**`APP_HOST` を apex ドメイン (`example.com` のような形) にする場合だけ**、Rails 側の `ssl_options` に `hsts: { subdomains: false }` を追加し、`dokku nginx:set tsumikura hsts-include-subdomains false` も合わせて設定する必要がある。

## 6. 環境変数

```bash
dokku config:set tsumikura \
  RAILS_MASTER_KEY=<config/master.key の中身> \
  RAILS_LOG_LEVEL=info \
  SOLID_QUEUE_IN_PUMA=1 \
  WEB_CONCURRENCY=0 \
  RAILS_MAX_THREADS=3 \
  TZ=Asia/Tokyo \
  APP_HOST=tsumikura.example.com \
  VAPID_PUBLIC_KEY=... VAPID_PRIVATE_KEY=... VAPID_SUBJECT=https://tsumikura.example.com \
  WEBAUTHN_ORIGIN=https://tsumikura.example.com \
  WEBAUTHN_RP_ID=tsumikura.example.com
```

`DATABASE_URL` は `dokku postgres:link` が自動設定する。

上記はこの構成で最終的に必要になる環境変数の一覧。

| 変数 | 必須 | 用途 |
|---|---|---|
| `RAILS_MASTER_KEY` | ○ | `config/credentials.yml.enc` の復号 |
| `DATABASE_URL` | ○ | `dokku postgres:link` が自動設定する |
| `RAILS_LOG_LEVEL` / `TZ` / `APP_HOST` | ○ | ログ量・タイムゾーン・ホスト名 |
| `SOLID_QUEUE_IN_PUMA` / `WEB_CONCURRENCY` / `RAILS_MAX_THREADS` / `JOB_CONCURRENCY` / `DB_POOL` | ○ / 任意 | Puma と Solid Queue の構成 |
| `VAPID_PUBLIC_KEY` | Web Push を使うなら | ブラウザに渡す公開鍵 (`<meta name="vapid-public-key">` と `pushManager.subscribe`) |
| `VAPID_PRIVATE_KEY` | Web Push を使うなら | 配信時の JWT 署名。**秘密鍵。ログにもリポジトリにも出さない** |
| `VAPID_SUBJECT` | Web Push を使うなら | 送信者の連絡先 (`https://...` か `mailto:...`)。未設定なら `mailto:admin@example.com` |
| `WEBAUTHN_ORIGIN` | 任意 | パスキーの origin (スキーム + ホスト)。未設定なら `https://$APP_HOST` を使う |
| `WEBAUTHN_RP_ID` | 任意 | パスキーの RP ID。**ホスト名のみ**。未設定なら origin のホスト名を使う |

**`VAPID_*` が未設定でもアプリは起動する** (通知だけが無効になる)。鍵の生成と設定の手順は
[初回デプロイ手順書 3.1 節](first-deploy.md#31-vapid-鍵-web-push)、
仕様は [通知](../spec/04-notifications.md#2-vapid-鍵の管理) を参照。
**鍵をローテーションすると既存の購読がすべて無効になる**ので、生成したら必ずバックアップする。

**`WEBAUTHN_*` は `APP_HOST` と同じドメインで公開するなら設定不要**
(未設定なら `https://$APP_HOST` とそのホスト名を使う)。非標準ポートや別ドメインのときだけ明示する。
**RP ID を後から変えると登録済みのパスキーがすべて使えなくなる**ので、ドメインは最初に決めて動かさない
(パスワードは常に有効なのでロックアウトはしない)。手順は [初回デプロイ手順書 3.2 節](first-deploy.md#32-webauthn-パスキー)、
仕様は [認証](../spec/05-auth.md#5-パスキー-webauthn) を参照。

`RAILS_MASTER_KEY` 等の秘密情報をシェル履歴や `ps` に残さずに投入する具体的な手順は [初回デプロイ手順書 3 節](first-deploy.md#3-環境変数) を参照。

## 7. 初回デプロイ手順

具体的な実行手順は [初回デプロイ手順書](first-deploy.md) に上から順に実行すれば終わる形でまとめている (前提確認・DNS、アプリ/DB 作成、秘密情報を履歴に残さない環境変数の設定、ドメイン/永続ストレージ、git push、Thruster の実地判断、Let's Encrypt (通知先メールアドレスの設定を含む)、初期管理者作成、動作確認チェックリスト、DB バックアップ、ロックアウト復旧)。ここでは流れの概要だけ示す。

1. 前提確認 (Dokku / プラグインのバージョン、DNS を早めに向ける)
2. アプリ作成、PostgreSQL サービス作成・link
3. 環境変数の設定
4. ドメイン設定、永続ストレージのマウント
5. git remote の追加、作業ブランチから dokku の `main` への push
6. Thruster の判断 (3.1 節。まず現状の Dockerfile のまま試す)
7. Let's Encrypt の有効化
8. 初回管理者の作成
9. 動作確認
10. DB バックアップの設定 (デプロイと同時に。後回しにしない)
11. ロックアウト時の復旧手順の確認

**確認すること**: `https://tsumikura.example.com/up` が 200 を返す / ログインできる / `dokku logs tsumikura -n 200` に Solid Queue の supervisor 起動ログが出る / セッション Cookie (`session_id`) に `secure` が付く (`force_ssl` が付ける。開発・test では付かないので本番でしか確かめられない)。curl でログインを確認する場合は CSRF トークンの取得が要るので、平文パスワードを使う単純な `curl -X POST` では `422` になる。具体的な確認コマンドは [初回デプロイ手順書 9 節](first-deploy.md#9-動作確認チェックリスト) を参照。

## 8. バックアップと復旧

| 項目 | 手段 |
|---|---|
| 日次バックアップ | `dokku postgres:backup-schedule` で S3 等へ (AWS 以外の S3 互換ストレージでは region・署名方式・エンドポイント URL も渡す)。または `dokku postgres:export` を cron で回す。手動で 1 回実行して確認するには `dokku postgres:backup tsumikura-db <bucket>`、スケジュール内容の確認は `dokku postgres:backup-schedule-cat tsumikura-db`。**Phase 5 のデプロイと同時に設定する** |
| リストア | `dokku postgres:import tsumikura-db < dump` |
| 管理者がパスワードを忘れた | `dokku run tsumikura bin/rails tsumikura:create_admin ADMIN_EMAIL=<その管理者> ADMIN_RESET_PASSWORD=1`。新しいパスワードが標準出力に 1 度だけ出て、そのユーザーのセッションはすべて失効する |
| 管理者が 1 人もいない / 対象が無効化されている | `dokku run tsumikura bin/rails tsumikura:create_admin ADMIN_EMAIL=<新しいアドレス> ADMIN_NAME=...` で**別の管理者を作る** (このタスクは無効化を解除しない)。ログイン後に `/admin/users` から元のユーザーを再有効化する |
| 在庫キャッシュの破損 | `dokku run tsumikura bin/rails stock:verify` で差異を検出し、`stock:recalculate` で台帳から再計算する |
| VAPID 鍵 | 鍵を失うと全購読が無効になる。`dokku config:show tsumikura` から退避しておく |

## 9. PostgreSQL のバージョン (18 以上が必須)

アプリのテーブルの主キーは UUIDv7 で、既定値に **PostgreSQL 18 のネイティブ関数 `uuidv7()`** を使う
(docs/spec/01-domain-model.md 2 節)。

`app.json` の predeploy は **`bundle exec rails db:prepare`**。空の DB では migration ではなく
**コミット済みの `db/schema.rb` の読み込み**になる (schema.rb は UUID 版がコミットされている)。
17 以前の PostgreSQL では、その schema.rb の読み込み中に
`PG::UndefinedFunction: ERROR: function uuidv7() does not exist` が出て predeploy が失敗し、
`git push` の出力にそのまま現れてデプロイが止まる。

- 開発 (`compose.yaml`) / CI (`.github/workflows/ci.yml`) / 本番 (dokku-postgres) のすべてを 18 にそろえる。
- dokku-postgres は**プラグインの既定イメージ**でサービスを作るので、環境によっては 17 以前になる。
  `dokku postgres:info tsumikura-db --version` で必ず確認する
  ([初回デプロイ手順書 2 節](first-deploy.md#2-アプリ作成postgresql-サービス作成link))。
- 18 未満だったときは、`--image-version 18` でサービスを作り直す (下の 10 節の手順がそのまま使える)。

## 10. スキーマを作り直す (主キーの UUIDv7 化)

Phase 13 のあと、アプリの全テーブルの主キーを連番の bigint から UUIDv7 に変えた
(docs/plan/implementation-plan.md)。**変換の migration は用意していない**。本番 DB は動作確認用で
捨ててよいので、**作り直す**のが手順になる。

> ### 作業の前に読むこと
>
> - **この作業で本番の全データが消える**: 品目、在庫の記録 (購入・使用・廃棄・棚卸)、買い物リスト、
>   ユーザー、Web Push の購読、パスキー。戻す手段は無い (手順 1 の退避は bigint のままの
>   ダンプなので、新しいスキーマには読み込めない。記録を見返すためだけのもの)。
> - **環境変数は消えない**: `RAILS_MASTER_KEY` / `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` /
>   `APP_HOST` / `WEBAUTHN_*` などは**アプリ側**に付いているので再設定は不要
>   (`dokku config:show tsumikura` で確認できる)。
> - **作業後にやること**: (1) `tsumikura:create_admin` で管理者を作り直す (2) 各端末で通知を
>   登録し直す (`/account`) (3) 各端末でパスキーを登録し直す (`/account`)
>   (4) **バックアップのスケジュールを設定し直す** (DB サービスごと作り直すので消える)。

> ### **DB を作り直す前に、このブランチを本番に push しない**
>
> migration のバージョン番号は変えずに中身だけ書き換えてあるので、bigint のままの DB に対して
> predeploy (`db:prepare`) は**「未適用の migration なし」で成功する**。デプロイは通るのに、
> そのあと `to_param` が整数の id を Base58 にしようとして `Base58Uuid::NotUuidPrimaryKey` になり、
> **全画面が 500 になる**。ログにこの例外が出ていたら、DB が古いということ。
>
> すでに push してしまった場合も、下の手順をそのまま実行すれば直る。ただし手順 5 の
> `git push` は `Everything up-to-date` になって何も起きないので、代わりに
> `dokku ps:rebuild tsumikura` で predeploy からやり直す。

```bash
# 1. 念のため今の中身を退避する (bigint のままのダンプ。新スキーマには読み込めない)
dokku postgres:export tsumikura-db > tsumikura-$(date +%Y%m%d).dump

# 2. アプリを止める。DATABASE_URL が無い状態で動いていると起動に失敗し続ける
dokku ps:stop tsumikura

# 3. link を外す。--no-restart はアプリの再起動を抑える
#    (フラグの有無は `dokku postgres:help unlink` で確認。無ければ付けずに実行してよい)
dokku postgres:unlink tsumikura-db tsumikura --no-restart

# 4. サービスを作り直す。--image-version 18 は必須ではないが、
#    プラグインの既定が 17 以前の環境では明示する (9 節)
dokku postgres:destroy tsumikura-db
dokku postgres:create tsumikura-db --image-version 18
dokku postgres:info tsumikura-db --version   # 18 であることを確認する

# 5. link し直す (DATABASE_URL が再設定される)。ここも --no-restart
#    (フラグの有無は `dokku postgres:help link` で確認)
dokku postgres:link tsumikura-db tsumikura --no-restart

# 6. 再デプロイ。app.json の predeploy (db:prepare) が空の DB に db/schema.rb を読み込む
git push dokku <ブランチ>:main
# すでに push 済みで Everything up-to-date になるときは、代わりにこれ
# dokku ps:rebuild tsumikura

# 7. 最初の管理者を作り直す
dokku run tsumikura bin/rails tsumikura:create_admin \
  ADMIN_EMAIL=admin@example.com ADMIN_NAME=かんりしゃ

# 8. バックアップのスケジュールを設定し直す (first-deploy.md 10 節)
dokku postgres:backup-auth tsumikura-db "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"
dokku postgres:backup-schedule tsumikura-db "0 4 * * *" <bucket>
dokku postgres:backup-schedule-cat tsumikura-db   # 設定内容を確認する
```

作り直したあとに戻す / 戻さないもの:

| もの | どうなるか |
|---|---|
| 環境変数 (`VAPID_*` / `WEBAUTHN_*` / `RAILS_MASTER_KEY` / `APP_HOST` など) | **アプリ側**に付いているので消えない。再設定は不要 (`dokku config:show tsumikura` で確認する) |
| バックアップのスケジュール | **サービス側**に付いているので `postgres:destroy` で消える。`postgres:backup-auth` と `postgres:backup-schedule` を**設定し直す** (手順 8 / [初回デプロイ手順書 10 節](first-deploy.md#10-db-バックアップの設定)) |
| Web Push の購読 | DB にあるので消える。各端末で通知を**登録し直す** (`/account` の「この端末で通知を受け取る」) |
| パスキー | DB にあるので消える。ログイン後に**登録し直す** (`/account`)。認証器側に残った古いパスキーは使えないので消してよい |
| ユーザー・品目・在庫の記録・買い物リスト | すべて消える。動作確認用のデータなので作り直す |

- コマンドの書式は `dokku postgres:help` で確認すること (プラグインのバージョンで引数が変わる)。
  `--no-restart` が無いプラグインでは付けずに実行してよい。手順 2 でアプリを止めてあるので、
  `link` / `unlink` が再起動を試みても止まったままになる (手順 6 の push / rebuild で起動し直る)。
- `postgres:destroy` は確認のためにサービス名の入力を求める。`--force` は使わない。
- **手順 2 を飛ばして `unlink` すると**、`DATABASE_URL` が消えたままアプリが再起動して落ち続ける。

### 作業後の確認

- `https://<ホスト>/up` が 200。
- ログインして品目を 1 件作り、**URL が `/items/<22 文字の Base58>` になっている**こと
  (連番でも 36 文字の UUID でもないこと)。
- `dokku logs tsumikura -n 200` に `Base58Uuid::NotUuidPrimaryKey` が出ていないこと
  (出ていたら DB が古いまま = 手順 3〜6 が効いていない)。

## 11. その他

- **Kamal 関連の削除**: `config/deploy.yml`、`.kamal/`、`bin/kamal`、`Gemfile` の `gem "kamal"`、`.dockerignore` の「Ignore Kamal files」ブロック。
- **Active Storage**: v1 では品目画像を扱わないので未使用。将来に備えて永続ストレージのマウントだけ用意しておいてもよい。

  ```bash
  dokku storage:ensure-directory tsumikura
  dokku storage:mount tsumikura /var/lib/dokku/data/storage/tsumikura:/rails/storage
  ```

  コンテナ内のアプリは非 root の `rails` ユーザー (Dockerfile の既定では uid 1000) で動くので、マウント元ディレクトリの所有者をそれに合わせる。
- **破壊的 migration**: `app.json` の predeploy が落ちるとデプロイが止まる (正しい挙動)。カラム削除などは 2 段階デプロイ (カラム追加 → コード変更 → 旧カラム削除) にする。
