# 開発環境

[デプロイ](deployment.md) / [概要](../spec/00-overview.md) / [実装計画](../plan/implementation-plan.md)

## 1. 前提

| 項目 | 値 |
|---|---|
| Ruby | 4.0.7 (`.ruby-version`) |
| Rails | 8.1.x |
| DB | PostgreSQL (Docker Compose で起動) |
| アセット | Propshaft + importmap + Tailwind CSS (tailwindcss-rails) |
| テスト | RSpec + FactoryBot + Capybara |
| ジョブ / キャッシュ | Solid Queue / Solid Cache (単一 DB) |

## 2. mise

グローバルの mise 設定が ruby 4.0.1 を固定しており、`.ruby-version` (4.0.7) が尊重されない。プロジェクトルートに `mise.toml` を置いて解決する。

```toml
# mise.toml
[tools]
ruby = "4.0.7"
```

- これで `mise x -- bin/rails ...` が 4.0.7 で動く。初回は `mise trust` が必要な場合がある。
- `mise trust` が使えない環境 (CI やサンドボックスなど) では、`MISE_TRUSTED_CONFIG_PATHS` 環境変数にプロジェクトのパスを設定して代替する。
- 代替案としてグローバル設定に `mise settings set idiomatic_version_file_enable_tools ruby` を入れる方法もあるが、プロジェクト完結の `mise.toml` を採る。

## 3. PostgreSQL (Docker Compose)

ローカルに `psql` が無いのでコンテナで立てる ([`compose.yaml`](../../compose.yaml))。

```yaml
services:
  postgres:
    image: postgres:18
    network_mode: host
    command: ["postgres", "-c", "listen_addresses=127.0.0.1"]
    environment:
      POSTGRES_USER: tsumikura
      POSTGRES_PASSWORD: tsumikura
      POSTGRES_DB: tsumikura_development
    volumes:
      - postgres-data:/var/lib/postgresql   # 18 以降のイメージはここ。17 以前を使うなら /var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -U tsumikura -d tsumikura_development"]
      interval: 5s
      timeout: 5s
      retries: 10

volumes:
  postgres-data:
```

- **ホストネットワーク + ループバック限定で動かす。** 開発マシンではホストから Docker ブリッジへの TCP がすべて拒否され (ping は通る)、`ports:` で公開しても `127.0.0.1:5432` から接続できなかった。ファイアウォールには手を入れず、コンテナをホストネットワークに置いて `listen_addresses=127.0.0.1` で待ち受ける。外部には公開されない。`network_mode: host` は Linux 専用。
- ブリッジが使える環境に移る場合は `network_mode` と `command` を外し、`ports: ["127.0.0.1:5432:5432"]` にする。Docker の公開ポートはホストのファイアウォール (ufw など) を迂回するので、`"5432:5432"` とは書かずループバックに限定すること。
- ホストの 5432 番を他の PostgreSQL が使っている場合は、`environment` に `PGPORT: 5433` を足して `DB_PORT=5433` で接続する (`PGPORT` はサーバにもヘルスチェックの `pg_isready` にも効く)。
- ヘルスチェックは `-h 127.0.0.1` で TCP を見る。初回起動時、公式イメージは initdb 用の一時サーバを Unix ソケットだけで立てるので、ソケットを見ると本サーバの起動前に healthy になってしまう。
- イメージは Alpine 版ではなく Debian 版 (`postgres:18`) を使う。Alpine (musl) は照合順序が実質 C になり、日本語の `ORDER BY` の結果が glibc の本番とずれるため。

メジャーバージョンは本番の dokku-postgres が作る DB に合わせる (Phase 5 で `dokku postgres:info tsumikura-db` を見て確認し、違っていれば揃える)。

`config/database.yml` の development / test を ENV フォールバック付きにする。

```yaml
default: &default
  adapter: postgresql
  encoding: unicode
  # Puma のスレッド数だけでは Solid Queue の supervisor (別プロセス) の接続要求を満たせないことが
  # あるため、既定で RAILS_MAX_THREADS + 2 にする (DB_POOL で明示上書きできる)。
  max_connections: <%= ENV.fetch("DB_POOL") { ENV.fetch("RAILS_MAX_THREADS", 3).to_i + 2 } %>
  host:     <%= ENV.fetch("DB_HOST",     "localhost") %>
  port:     <%= ENV.fetch("DB_PORT",     5432) %>
  username: <%= ENV.fetch("DB_USERNAME", "tsumikura") %>
  password: <%= ENV.fetch("DB_PASSWORD", "tsumikura") %>

development:
  <<: *default
  database: tsumikura_development

test:
  <<: *default
  database: tsumikura_test

production:
  <<: *default
```

CI や本番では `DATABASE_URL` が自動でマージされて上書きするので、この記述と両立する。

起動:

```bash
docker compose up -d --wait
mise x -- bin/rails db:prepare
mise x -- bin/dev            # Tailwind の watch + Puma
```

`bin/setup` の先頭に `docker compose up -d --wait` を足してもよいが、Docker 必須になるので README に手順を書く方を採る。

## 4. RSpec / FactoryBot

t_wada 流 TDD (Red → Green → Refactor、TODO リスト駆動、小さなステップ) で進めるため、テストは最初期に整える。

```ruby
# Gemfile
group :development, :test do
  gem "rspec-rails"
  gem "factory_bot_rails"
end

group :test do
  gem "capybara"
  gem "selenium-webdriver"
  gem "shoulda-matchers"   # 任意
end
```

```bash
mise x -- bundle install
mise x -- bin/rails generate rspec:install    # .rspec, spec/spec_helper.rb, spec/rails_helper.rb
mise x -- bundle binstubs rspec-core          # bin/rspec
rm -rf test/                                  # Minitest のディレクトリを削除
```

`config/application.rb`:

```ruby
config.generators do |g|
  g.test_framework :rspec,
    fixture: true, view_specs: false, helper_specs: false, routing_specs: false
  g.fixture_replacement :factory_bot, dir: "spec/factories"
end
```

`.rspec`:

```
--require spec_helper
--format documentation
```

`spec/rails_helper.rb` への追記 (`config.include FactoryBot::Syntax::Methods` は `spec/support/factory_bot.rb` 側に置き、下の 1 行で読み込む):

```ruby
Rails.root.glob("spec/support/**/*.rb").sort_by(&:to_s).each { |f| require f }
config.infer_spec_type_from_file_location!
config.filter_rails_from_backtrace!
```

ディレクトリ構成:

```
spec/
  models/          # AR モデル + PORO (forecast/ を含む)
  requests/        # コントローラ層
  system/          # Capybara (headless chrome)
  factories/
  support/
    factory_bot.rb
    authentication_helper.rb   # sign_in(user)
    webauthn_helper.rb
    capybara.rb
```

**`spec/models/forecast/` のうち PORO (`calculator` / `window` など) の spec は `rails_helper` ではなく `spec_helper` のみを require** して、DB なしで高速に回す ([予測](../spec/02-forecast.md))。Rails のオートロードが効かないので、spec の先頭で対象ファイルを `require_relative` する。DB を使う `snapshot_builder` / `batch_forecaster` の spec は通常どおり `rails_helper` を使う。

**system spec のドライバ方針** (`spec/support/capybara.rb`):

- 既定 (`type: :system`) は `driven_by :rack_test`。ブラウザを起動しないので DB 接続だけあれば速く動く。
- `js: true` を付けた spec だけ `driven_by :selenium, using: :headless_chrome, screen_size: [ 390, 844 ]` (スマホ幅) を使う。
- `ENV["GITHUB_ACTIONS"]` が無く (`bin/ci` も `ENV["CI"]` を立てるので `CI` では判定しない)、かつ `google-chrome` / `google-chrome-stable` / `chromium` / `chromium-browser` のいずれも `PATH` に見つからないときは、Selenium Manager にブラウザ/ドライバをダウンロードさせず `skip` する。CI では常に実行する (GitHub Actions の `ubuntu-latest` には Chrome がプリインストールされている)。
- 失敗時のスクリーンショットの保存先は **`tmp/capybara`** (`Capybara.save_path`)。rspec-rails が `rspec/rails` の require 時に `capybara/rails` を require し、そこで `Capybara.save_path = Rails.root.join("tmp/capybara")` が設定される。Rails の `ActionDispatch::SystemTesting::TestHelpers::ScreenshotHelper#screenshots_dir` は `Capybara.save_path.presence || "tmp/screenshots"` なので、既定 (`tmp/screenshots`) ではなく `tmp/capybara` になる。CI の artifact path もここに合わせる。

## 5. Tailwind CSS

```bash
mise x -- bundle add tailwindcss-rails
mise x -- bin/rails tailwindcss:install
```

- tailwindcss-rails は `tailwindcss-ruby` gem 経由でスタンドアロン CLI バイナリを使うので **Node.js は不要**。
- インストーラが `app/assets/tailwind/application.css`、`Procfile.dev`、`bin/dev` を生成し、レイアウトの `stylesheet_link_tag` を書き換える。**生成結果に合わせてレイアウトを調整する** (Propshaft 連携の出力先はバージョンで変わるため、実行後に実物を確認する)。
  - 確認結果 (tailwindcss-rails 4.6.0 + Propshaft): レイアウトに既に `stylesheet_link_tag :app` があったため、インストーラは別枠の `stylesheet_link_tag "tailwind"` を**追加しなかった**。`:app` は `app/assets/**/*.css` を束ねて読み込むシンボルで、`Tailwindcss::Engine` が `app/assets/tailwind` (ソースの `@import "tailwindcss";`) を `config.assets.excluded_paths` に加えるため、ロードパスに乗るのはビルド成果物の `app/assets/builds/tailwind.css` だけになる。二重読み込みや衝突はない。
- `bin/rails assets:precompile` が `tailwindcss:build` を自動実行するので **Dockerfile の変更は不要**。
- **spec の前に Tailwind のビルドが必要。** tailwindcss-rails が `tailwindcss:build` を足す (enhance する) のは `test:prepare` だけで (`rails/all` が test_unit の railtie を読み込むため、`spec:prepare` / `db:test:prepare` の分岐には入らない)、RSpec では呼ばれない。ビルド成果物 `app/assets/builds/tailwind.css` は gitignore 対象で、無くても Propshaft は例外を出さず link が出ないだけなので、スタイルシートを検証する system spec が落ちる。ローカルは `bin/setup` がビルドし、GitHub Actions は `bin/rails db:test:prepare tailwindcss:build` と明示する。
- `.gitignore` に `/app/assets/builds/*` + `!/app/assets/builds/.keep` が追加されることを確認する (`.dockerignore` には既に記載あり)。

## 6. 日本語化

```ruby
# Gemfile
gem "rails-i18n"

# config/application.rb
config.time_zone = "Asia/Tokyo"
config.i18n.default_locale = :ja
config.i18n.available_locales = [ :ja ]
```

- `config/locales/ja.yml` に `activerecord.models` / `activerecord.attributes` とビュー文言を定義する。
- `config/locales/en.yml` は削除する。
- 日付フォーマットは `date.formats.default: "%Y/%m/%d"`。
- `config.active_record.default_timezone` は既定の `:utc` のまま (DB は UTC、表示は JST)。`Date.current` が JST 基準になるので、`used_on` などの日付は期待どおりに動く。

## 7. アプリ設定ファイル

`config/tsumikura.yml` を置き、`Rails.application.config_for(:tsumikura)` で読む。内容は [予測と要購入判定](../spec/02-forecast.md) を参照。

## 8. CI

`.github/workflows/ci.yml`:

| ジョブ | 変更内容 |
|---|---|
| `test` | `bin/rails db:test:prepare test` → `bin/rails db:test:prepare tailwindcss:build` の後に `bundle exec rspec --exclude-pattern "spec/system/**/*_spec.rb"` |
| `system-test` | `bin/rails db:test:prepare test:system` → `bin/rails db:test:prepare tailwindcss:build` の後に `bundle exec rspec spec/system` |
| `system-test` | 失敗時スクリーンショットの `path` は `tmp/capybara` (確認済み。4 節末尾参照) |
| `test` / `system-test` | `bin/rails db:test:prepare tailwindcss:build` として Tailwind を明示的にビルドする (5 節。`db:test:prepare` だけではビルドされない) |
| 全ジョブ | `ruby/setup-ruby@v1` は `.ruby-version` を読む。[`ruby-builder-versions.json`](https://github.com/ruby/setup-ruby/blob/master/ruby-builder-versions.json) に `4.0.7` が載っていることは確認した (2026-09-19)。実際にセットアップできるかは GitHub Actions の初回実行で確認する ([未決事項](../plan/open-questions.md)) |
| `scan_ruby` / `scan_js` / `lint` | 変更なし |

`config/ci.rb` (`bin/ci` から読まれる):

```ruby
CI.run do
  step "Setup", "bin/setup --skip-server"
  step "Style: Ruby", "bin/rubocop"
  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"
  step "Tests: RSpec", "bin/rspec --exclude-pattern 'spec/system/**/*_spec.rb'"
  step "Tests: System", "bin/rspec spec/system"
  step "Tests: Seeds", "env RAILS_ENV=test bin/rails db:seed:replant"
end
```

- `bin/setup --skip-server` が `db:prepare` を実行するので、手元では先に `docker compose up -d --wait` を済ませておく。
- `db/seeds.rb` は **ENV なしでも成功する冪等な実装**にする (CI の `db:seed:replant` を通すため)。

## 9. よく使うコマンド

```bash
docker compose up -d --wait          # PostgreSQL 起動
mise x -- bin/rails db:prepare       # DB 作成・マイグレーション
mise x -- bin/dev                    # 開発サーバ (Tailwind watch 付き)
mise x -- bin/rspec                  # 全テスト
mise x -- bin/rspec spec/models/forecast   # 予測ロジックだけ (DB 不要・高速)
mise x -- bin/rubocop                # 静的解析
mise x -- bin/ci                     # CI と同じ一式
mise x -- bin/rails stock:verify     # 在庫キャッシュの差異検出
```
