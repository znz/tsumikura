# デプロイ (Dokku)

[開発環境](development.md) / [概要](../spec/00-overview.md) / [通知](../spec/04-notifications.md) / [未決事項](../plan/open-questions.md)

既存の Dokku サーバに同居させる。Dockerfile デプロイ + 単一 `DATABASE_URL` + `SOLID_QUEUE_IN_PUMA` で、**アプリのコンテナは 1 つ**にする。Kamal は使わないので関連ファイルを削除する。

## 1. 単一 DB 化

`rails new` 直後の `config/database.yml` の production は `primary` / `cache` / `queue` / `cable` の 4 接続になっている。dokku-postgres が渡す単一の `DATABASE_URL` に寄せる。

### 1.1 Solid Cable を削除する (確定)

リアルタイム同期は不要と決めたので、**`solid_cable` は削除する**。

- `Gemfile` から `gem "solid_cable"` を削除し、`db/cable_schema.rb` を削除する。
- `config/cable.yml` は production も `adapter: async` にする (未使用のまま残す形でもよい)。
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

## 3. Dockerfile

| 項目 | 現状 | 変更 | 理由 |
|---|---|---|---|
| `BUNDLE_WITHOUT` | `"development"` | `"development:test"` | RSpec / Capybara / Selenium を本番イメージに入れない |
| Thruster | `CMD ["./bin/thrust", "./bin/rails", "server"]` / `EXPOSE 80` | **Phase 5 (初回デプロイ) で決める。下記参照** | — |

`bin/docker-entrypoint` の `db:prepare` は削除し、マイグレーションは `app.json` の predeploy に一本化する (4 節)。

### 3.1 Thruster をどうするか (未決)

Dokku は Dockerfile の `EXPOSE` を読んでポートマッピングを作る。Thruster は `HTTP_PORT` (既定 80) で待ち受けて `TARGET_PORT` (既定 3000) の Puma に流す。Dokku 側のポートマッピングや `PORT` 環境変数の扱いと噛み合うかを**初回デプロイで実地に確認してから**決める。

**案 A: Thruster を外して Puma 直起動**

```dockerfile
EXPOSE 3000
CMD ["./bin/rails", "server"]
```

- `Gemfile` から `gem "thruster"` を削除し、`bin/thrust` も削除する。
- 前段に Dokku の nginx がいるので、Thruster の圧縮・キャッシュ・X-Sendfile の価値は限定的。
- ポートの取り合いが起きないので構成が単純になる。

**案 B: Thruster を残す**

- `EXPOSE 80` のまま。`dokku ports:set tsumikura http:80:80` を確認する。
- `TARGET_PORT` (Puma の待ち受け) を明示し、Dokku が注入する `PORT` と衝突しないことを確認する。
- 静的アセットの gzip / brotli 配信と X-Sendfile が使える。将来 Dokku 以外へ移すときに構成を変えずに済む。

**判断材料**

| 観点 | 案 A | 案 B |
|---|---|---|
| ポート設定の事故 | 起きにくい | `PORT` / `HTTP_PORT` / `TARGET_PORT` の 3 つが絡む |
| 静的配信の性能 | Rails (Propshaft) が返す。家庭用の同時 1〜5 人なら十分 | Thruster が圧縮・キャッシュする |
| 生成物からの乖離 | `rails new` の既定から外れる | 既定のまま |
| 切り戻し | いつでも戻せる (Gemfile と Dockerfile の数行) | 同左 |

初回デプロイで案 B が素直に動けばそのまま残し、ポート周りでつまずいたら案 A に倒す。決定したら本節と [未決事項](../plan/open-questions.md) を更新する。

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

- `predeploy` は新しいイメージで、トラフィックを流す前に実行される。`db:prepare` (create + schema load + migrate) の置き場所として適切。
- `postdeploy` は使わない。初期管理者の作成は冪等性と可視性のために手動実行とする。
- ヘルスチェックの `/up` は Rails 既定の `rails/health#show` をそのまま使う。

## 5. SSL とホスト認可

`config/environments/production.rb` で以下を有効にする。

```ruby
config.assume_ssl = true          # nginx が X-Forwarded-Proto を付ける
config.force_ssl  = true          # HSTS + secure cookie
config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

config.hosts = [ ENV.fetch("APP_HOST", "localhost") ]
config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
```

- Dokku の nginx が TLS を終端し、アプリには http で到達する。`assume_ssl = true` がないと `force_ssl` が無限リダイレクトを起こす。
- **`/up` を SSL リダイレクトとホスト認可の両方から除外する**のが重要。Dokku の内部ヘルスチェックはコンテナに直接 http でアクセスするため、除外しないとデプロイがヘルスチェックで失敗する。
- `dokku-letsencrypt` の ACME チャレンジ (`/.well-known/acme-challenge`) は nginx が直接応答するのでアプリには届かない。`force_ssl` を先に入れても証明書の発行は成功する。

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

## 7. 初回デプロイ手順

```bash
# サーバ側
dokku apps:create tsumikura
dokku postgres:create tsumikura-db
dokku postgres:link tsumikura-db tsumikura
dokku domains:set tsumikura tsumikura.example.com
dokku config:set tsumikura <上記の環境変数>

# 手元から
git remote add dokku dokku@example.com:tsumikura
git push dokku main

# 証明書
dokku letsencrypt:enable tsumikura

# 初期管理者
dokku run tsumikura bin/rails tsumikura:create_admin \
  ADMIN_EMAIL=admin@example.com ADMIN_NAME=かんりしゃ

# バックアップ (後回しにしない)。先に保存先の認証情報を登録する
dokku postgres:backup-auth tsumikura-db <access-key-id> <secret-access-key>
dokku postgres:backup-schedule tsumikura-db "0 4 * * *" <bucket>
```

**確認すること**: `https://tsumikura.example.com/up` が 200 を返す / ログインできる / `dokku logs tsumikura` に Solid Queue の supervisor 起動ログが出る。

## 8. バックアップと復旧

| 項目 | 手段 |
|---|---|
| 日次バックアップ | `dokku postgres:backup-schedule` で S3 等へ。または `dokku postgres:export` を cron で回す。**Phase 5 のデプロイと同時に設定する** |
| リストア | `dokku postgres:import tsumikura-db < dump` |
| 管理者ロックアウト | `dokku run tsumikura bin/rails tsumikura:create_admin ADMIN_EMAIL=... ADMIN_NAME=...` (冪等) |
| 在庫キャッシュの破損 | `dokku run tsumikura bin/rails stock:verify` で差異を検出し、`stock:recalculate` で台帳から再計算する |
| VAPID 鍵 | 鍵を失うと全購読が無効になる。`dokku config:show tsumikura` から退避しておく |

## 9. その他

- **Kamal 関連の削除**: `config/deploy.yml`、`.kamal/`、`bin/kamal`、`Gemfile` の `gem "kamal"`、`.dockerignore` の「Ignore Kamal files」ブロック。
- **Active Storage**: v1 では品目画像を扱わないので未使用。将来に備えて永続ストレージのマウントだけ用意しておいてもよい。

  ```bash
  dokku storage:ensure-directory tsumikura
  dokku storage:mount tsumikura /var/lib/dokku/data/storage/tsumikura:/rails/storage
  ```

  コンテナ内のアプリは非 root の `rails` ユーザー (Dockerfile の既定では uid 1000) で動くので、マウント元ディレクトリの所有者をそれに合わせる。
- **破壊的 migration**: `app.json` の predeploy が落ちるとデプロイが止まる (正しい挙動)。カラム削除などは 2 段階デプロイ (カラム追加 → コード変更 → 旧カラム削除) にする。
