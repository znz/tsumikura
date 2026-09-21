# 初回デプロイ手順 (Dokku)

[デプロイ構成](deployment.md) / [開発環境](development.md) / [実装計画](../plan/implementation-plan.md) / [未決事項](../plan/open-questions.md)

Phase 5 (ウォーキングスケルトンの本番デプロイ) の手順書。上から順に実行すれば終わる形にしている。前提として [デプロイ構成](deployment.md) を読んでいること。リポジトリ側の準備 (`app.json`、`config/environments/production.rb` の SSL/hosts 設定、`bin/docker-entrypoint` からの `db:prepare` 削除) は完了している。

**表記**: 特に注記のないコマンドは既存の Dokku サーバにログインしたシェルで実行する。「手元」は自分の作業マシン (このリポジトリのチェックアウト) を指す。

サーバのシェルにログインしたら、まずドメインを 1 か所だけ設定する (以降のサーバ側コマンドはこの変数を使う)。SSH を張り直すなどでシェルが変わったら、この 2 行をセットでやり直す (`export` だけ忘れて `APP_HOST` が空文字のまま進んでしまう事故を防ぐ)。

```bash
export APP_HOST=tsumikura.example.com   # 実際のドメインに置き換える
: "${APP_HOST:?先に export APP_HOST=... を実行すること}"
```

## 1. 前提の確認

```bash
dokku version
dokku plugin:list | grep -E 'postgres|letsencrypt'
docker version   # Client/Server が 20.10 以上か確認する (6 節の Thruster 判断に関わる。確認事項参照)
```

- `postgres` と `letsencrypt` のプラグインが `enabled` であることを確認する。既存の Dokku サーバに同居させる想定なので、通常はすでに入っている。
- 入っていない場合のみ:

  ```bash
  sudo dokku plugin:install https://github.com/dokku/dokku-postgres.git --name postgres
  sudo dokku plugin:install https://github.com/dokku/dokku-letsencrypt.git
  ```

- **DNS**: `$APP_HOST` の A/AAAA レコードを、このドキュメントを読み終える前に (反映に時間がかかることがあるので早めに) この Dokku サーバの IP に向けておく。7 節 (Let's Encrypt) はデプロイ成功かつ DNS 反映後にしか実行できない。

  ```bash
  dig +short $APP_HOST
  ```

  まだ反映されていなくても 2〜6 節の作業は進められる。DNS 反映前にサーバ上で疎通確認したい場合は、Host ヘッダを直接指定する。

  ```bash
  # デプロイ後、サーバ上で
  curl -sI -H "Host: $APP_HOST" http://localhost/up
  ```

## 2. アプリ作成、PostgreSQL サービス作成、link

```bash
dokku apps:create tsumikura
dokku git:set tsumikura deploy-branch main
dokku git:report tsumikura   # "Git deploy branch" が main になっていることを確認する
```

`deploy-branch` を明示しておくと、5 節の `git push dokku <ブランチ>:main` の `main` が確実にデプロイ対象になる (既定でも通常 `main` だが、念のため明示する)。

> **既存の Dokku 環境では**: dokku-postgres プラグインが既に入っていて、既存のサービスが動いていることがある。その場合もサービス自体は**アプリごとに分けて作る** (下の `tsumikura-db`)。既存のサービスを共用しない。プラグインの既定イメージのバージョンは既存の環境に合わせて決まるので、下のとおり作ってから確認する。
>
> ```bash
> dokku postgres:list   # 既存のサービスを確認する (名前が衝突しないこと)
> ```
>
> **2026-09-21 の初回デプロイの結果: 作成された PostgreSQL は 18 で、開発用 `compose.yaml` の `postgres:18` と同じだった。`compose.yaml` の変更は不要。**

PostgreSQL サービスを作る前に、開発用 [`compose.yaml`](../../compose.yaml) が `postgres:18` を使っていることを確認しておく。既定の手順は、**バージョンを指定せずプラグインの既定イメージで作成し、実際のバージョンを確認してから `compose.yaml` 側を合わせる**。

```bash
dokku postgres:create tsumikura-db
dokku postgres:info tsumikura-db --version
```

- 確認した値が `compose.yaml` の `postgres:18` と異なる場合は、`compose.yaml` の `image: postgres:18` をそのバージョンに合わせて修正する (開発と本番のメジャーバージョンを揃えておく)。
- 明示的に `18` を指定して作りたい場合は `dokku postgres:create tsumikura-db --image-version 18` が使えるが、先に `sudo dokku plugin:update postgres` でプラグインを更新しておく。**PostgreSQL 18 はデータディレクトリが `/var/lib/postgresql` に変わっている。未対応の古いプラグインで指定すると、データが永続ボリュームの外に置かれる恐れがある**。`grep -n PG_MAJOR /var/lib/dokku/plugins/available/postgres/functions` でプラグインが 18 を認識しているか確認してから使う (確認事項参照)。

作成したアプリに link する (まだ push していないので再起動は起きない)。`DATABASE_URL` は自動で設定される。

```bash
dokku postgres:link tsumikura-db tsumikura
dokku config:get tsumikura DATABASE_URL   # 設定されたことを確認する
```

## 3. 環境変数

秘密情報 (`RAILS_MASTER_KEY`) をシェルの履歴や `ps` に残さないよう、`read -rs` で受け取ってから `dokku config:set` に渡す。まず手元で `config/master.key` の内容を確認する。

```bash
# 手元で
cat config/master.key
```

サーバ側で、確認した値を貼り付けて設定する (画面にも履歴にも残らない)。初回デプロイ前なので `--no-restart` を付ける (まだ起動していないアプリの再起動は不要)。

```bash
: "${APP_HOST:?先に export APP_HOST=... を実行すること}"
read -rs RAILS_MASTER_KEY   # config/master.key の内容を貼り付けて Enter
dokku config:set --no-restart tsumikura \
  RAILS_MASTER_KEY="$RAILS_MASTER_KEY" \
  RAILS_LOG_LEVEL=info \
  SOLID_QUEUE_IN_PUMA=1 \
  WEB_CONCURRENCY=0 \
  RAILS_MAX_THREADS=3 \
  TZ=Asia/Tokyo \
  APP_HOST="$APP_HOST"
unset RAILS_MASTER_KEY
```

手元の端末から SSH で直接実行してもよい (この場合も履歴に残らない)。

```bash
# 手元で
ssh -t dokku@<Dokku サーバのホスト名> config:set --no-restart tsumikura RAILS_MASTER_KEY="$(cat config/master.key)"
```

`dokku` プロセスの実行中の引数として一瞬 `ps` に見えるのは `config:set` の仕組み上避けられない。デプロイ後に VAPID / WEBAUTHN の値を追加するときは、既に起動しているアプリを再起動してよいので `--no-restart` を外す。

- `SOLID_QUEUE_IN_PUMA=1`: Puma に Solid Queue の supervisor を同居させる ([デプロイ構成](deployment.md#2-ジョブの実行-solid_queue_in_puma))。
- `WEB_CONCURRENCY=0`: Puma を single mode にする (ワーカープロセスなし)。
- `RAILS_MAX_THREADS=3`: Puma のスレッド数。`config/database.yml` の `max_connections` はこの値に Solid Queue supervisor 分の余裕 (+2) を足した数を既定にしている (`DB_POOL` で明示上書きできる。[デプロイ構成](deployment.md#2-ジョブの実行-solid_queue_in_puma))。
- `VAPID_*` (Web Push) は次の 3.1 節で設定する。初回デプロイ前に入れておくと、デプロイ直後から通知を試せる。
- `WEBAUTHN_*` (パスキー) は 3.2 節。**`APP_HOST` と同じドメインで公開するなら設定しなくてよい**
  (未設定なら `https://$APP_HOST` を使う)。

### 3.1 VAPID 鍵 (Web Push)

**鍵は手元で生成する。** サーバで生成すると、控えを取り損ねたときに復元できない
([通知](../spec/04-notifications.md#2-vapid-鍵の管理))。

```bash
# 手元のリポジトリで (1 回だけ)
mise x -- ruby -rweb_push -e 'p WebPush.generate_key.to_h'
# => {:public_key=>"BN...=", :private_key=>"7p...="}
```

**出力された 2 つの値をすぐにパスワードマネージャへ退避する。**
`VAPID_PRIVATE_KEY` は秘密鍵なので、リポジトリにもチャットにも貼らない。

サーバ側で、貼り付けて設定する (`read -rs` なので画面にも履歴にも残らない)。
まだデプロイしていない段階なら `--no-restart` を付ける。デプロイ後に追加するときは外す
(アプリを再起動して初期化子に読ませる必要がある)。

```bash
: "${APP_HOST:?先に export APP_HOST=... を実行すること}"
read -rs VAPID_PUBLIC_KEY    # 生成した public_key を貼り付けて Enter
read -rs VAPID_PRIVATE_KEY   # 生成した private_key を貼り付けて Enter
dokku config:set tsumikura \
  VAPID_PUBLIC_KEY="$VAPID_PUBLIC_KEY" \
  VAPID_PRIVATE_KEY="$VAPID_PRIVATE_KEY" \
  VAPID_SUBJECT="https://$APP_HOST"
unset VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY
```

- `VAPID_SUBJECT` は Push サービスが送信者を問い合わせるための連絡先。`https:` か `mailto:` のどちらか。
- **鍵をローテーションすると既存の購読がすべて無効になる** (配信が 401 になり、家族全員が
  `/account` で登録し直すことになる)。安易に作り直さない。
- 鍵が未設定でもアプリは起動する。`/account` の通知セクションが
  「サーバに通知の鍵が設定されていません。」になるだけなので、後から設定してもよい。

> **アイコンについて**: 原本は `public/icon.svg` で、PWA と iOS 用の PNG は
> `script/generate_icons.sh` がそこから作る (`icon.png` / `icon-192.png` /
> `icon-maskable.png` / `apple-touch-icon.png`)。デザインを変えるときは `icon.svg` を直して
> スクリプトを実行し直し、生成された PNG ごとコミットする
> ([通知](../spec/04-notifications.md#1-pwa-の有効化))。

### 3.2 WEBAUTHN (パスキー)

パスキーは [認証](../spec/05-auth.md#5-パスキー-webauthn) のとおり **origin** (スキーム + ホスト) と
**RP ID** (ホスト名だけ) を見て検証する。

**`APP_HOST` と同じドメインで HTTPS 公開するなら、設定は要らない。**
アプリが `WEBAUTHN_ORIGIN` を `https://$APP_HOST`、`WEBAUTHN_RP_ID` をそのホスト名として導く。

次のどれかに当てはまるときだけ明示する。

- 非標準ポートで公開する (`https://tsumikura.example.com:8443` など)
- アプリのドメイン (`APP_HOST`) と、家族が実際に開く URL が違う
- apex ドメインでも登録済みのパスキーを使えるようにしたい (RP ID を親ドメインにする)

```bash
: "${APP_HOST:?先に export APP_HOST=... を実行すること}"
dokku config:set tsumikura \
  WEBAUTHN_ORIGIN="https://$APP_HOST" \
  WEBAUTHN_RP_ID="$APP_HOST"
```

- **`WEBAUTHN_RP_ID` はホスト名だけ。** `https://` を付けたりパスを足したりすると、ブラウザが
  登録そのものを拒否する (`SecurityError`)。
- **RP ID を後から変えると、登録済みのパスキーはすべて使えなくなる。** 家族全員がパスワードで
  ログインし直して `/account` から登録し直すことになるので、ドメインは最初に決めて動かさない。
  (パスワードは常に有効なので、ロックアウトはしない。)
- 秘密情報ではないので `read -rs` は不要。`dokku config:show tsumikura` で確認できる。
- パスキーは `localhost` 以外では **HTTPS が必須**。7 節 (Let's Encrypt) を済ませてから試す。
  実機での確認手順は [認証](../spec/05-auth.md#実機での確認手順-https-の本番環境で) にある。

## 4. ドメイン設定、永続ストレージのマウント

> **既存の Dokku 環境では**: 他のアプリが動いている Dokku サーバでは、**global domain が既に設定済み**のことがある (その場合、アプリを作った時点で `<app>.<global domain>` が自動で付く)。その場合は下の `domains:set` を飛ばすか、既存の設定に合わせる。まず確認する。
>
> ```bash
> dokku domains:report --global   # global domain の設定を見る (サブコマンドの有無は dokku domains:help で確認)
> dokku domains:report tsumikura  # このアプリに何が付いているか
> ```
>
> 2026-09-21 の初回デプロイでは、既存環境に global な設定があったのでこの節は読み替えて実施した。

他のアプリが同じドメインを既に使っていないか確認する (2 つのアプリに同じドメインを設定すると nginx の server name が衝突する)。

```bash
dokku domains:report tsumikura
```

**確認事項**: 他アプリ分も含めて一括確認できるかはプラグインのバージョンに依存する。見当たらない場合は `dokku apps:list` と組み合わせて各アプリの `dokku domains:report <app>` を確認する。

```bash
: "${APP_HOST:?先に export APP_HOST=... を実行すること}"
dokku domains:set tsumikura $APP_HOST
```

v1 では Active Storage を使わないが、将来 (品目の写真) に備えて永続ストレージのマウントだけ用意しておく ([デプロイ構成](deployment.md#9-その他))。コンテナ内のアプリは非 root の `rails` ユーザー (uid/gid 1000、`Dockerfile` の既定) で動くので、マウント元ディレクトリの所有者をそれに合わせる。`--chown heroku` を付けると uid/gid 1000 の所有者で作成される (確認事項: このオプションが無い古いプラグインでは `sudo chown -R 1000:1000 /var/lib/dokku/data/storage/tsumikura` で代替する)。

```bash
dokku storage:ensure-directory --chown heroku tsumikura
dokku storage:mount tsumikura /var/lib/dokku/data/storage/tsumikura:/rails/storage
```

## 5. git remote の追加と初回 push

> **push するブランチは読み替える。** 下の例は Phase 5 当時のブランチ名。**その時点の作業ブランチ**を `git push dokku <そのブランチ>:main` の形で push する (GitHub に push していなくてもよい。Dokku は別の remote)。2026-09-21 の初回デプロイは `phase-13-passkeys` を `git push dokku phase-13-passkeys:main` で push した。

```bash
# 手元で
git remote add dokku dokku@<Dokku サーバのホスト名>:tsumikura
```

現在の作業ブランチ (`phase-5-dokku-deploy`) は積み上げ式で、ローカルの `main` にはまだマージされていない。ローカルの `main` を push しても Phase 5 の変更 (`app.json`、SSL 設定など) が反映されないので、**作業ブランチの内容を直接 dokku の `main` に push する**。

```bash
# 手元で
git push dokku phase-5-dokku-deploy:main
```

以降、別のブランチで作業を続けている間は同様に `git push dokku <そのブランチ>:main` で再デプロイする。すべてローカルの `main` にマージした後は `git push dokku main` に戻せる。

この push で `app.json` の `predeploy` (`bundle exec rails db:prepare`) が走り、`healthchecks.web` の `/up` チェックに通ってからトラフィックが切り替わる。**predeploy の実行ログは `dokku logs` ではなく、この `git push` コマンド自体の出力に出る** (`Executing predeploy task from app.json ...` という行)。デプロイ (ビルド) 自体が失敗した場合は `dokku logs:failed tsumikura` で直前の失敗したビルドのログを確認する。デプロイ後のアプリのログは `dokku logs tsumikura -n 200` で確認する (`--tail` は「以後のログに追従する」ブールオプションで、単発確認には使わない)。

コードを変更せずに再デプロイしたいだけの場合 (`git push` は同じコミットなら「Everything up-to-date」になり何も起きない) は `dokku ps:rebuild tsumikura` を使う。

## 6. Thruster の判断 (決定済み: 案 B)

> **決定 (2026-09-21)**: **案 B (Thruster を残す。`Dockerfile` を変更しない) で確定。**
> 初回デプロイで `Dockerfile` をそのままにして問題なく動いた (`ports:set` も不要だった)。
> この節は**確認だけ**行えばよい。下の「うまくいかない場合」以降 (案 A への切り替え差分) は
> **参考 (使わなかった)** として残してある。

査読 (Dokku / Thruster のソースと公式ドキュメント) で分かったこと: Dockerfile デプロイで Dokku はコンテナに `PORT` 環境変数を注入する (`EXPOSE 80` なら `PORT=80`)。一方 Thruster は自分の待ち受けポートに `PORT` を使わず `HTTP_PORT` (既定 80) を見て、子プロセス (Puma) を起動するときは `PORT` を `TARGET_PORT` (既定 3000) で上書きして渡す。したがって Dokku が注入する `PORT` と Thruster / Puma の間でポートの取り合いは起きにくい。残る懸念は非 root (uid 1000) での 80 番への bind だけで、Docker 20.10 以降のブリッジネットワークでは通常問題ない (1 節で確認済み。確認事項も参照)。

現状の Dockerfile (案 B: Thruster を残す、変更なし) のままデプロイする。5 節の push で既にこのイメージがデプロイされているので、ここでは確認だけ行う。

```bash
# サーバ側
dokku ports:report tsumikura
curl -sI http://$APP_HOST/up
dokku logs tsumikura -n 200
```

**うまくいっている場合**: `ports:report` に `Ports map detected: http:80:80` が出る (`EXPOSE 80` からの自動検出。明示設定していないので `Ports map:` 自体は空でよい)。`curl` が `200` を返し (証明書がまだ無ければ http のまま)、ログに Puma や Thruster のエラーが無い。**2026-09-21 の初回デプロイはこのとおりだったので、ここで完了。以下は読み飛ばしてよい。**

**以下は参考 (使わなかった)。うまくいかない場合の症状**:

- `dokku logs tsumikura -n 200` に `listen tcp :80: bind: permission denied` が出る (非 root ユーザーでの 80 番 bind に失敗している。Docker が古い場合に起きうる)
- `curl` が `502 Bad Gateway` を返す、または繋がらない (nginx がコンテナの 80 番に接続できていない)

この場合は **案 A (Thruster を外して Puma 直起動、`EXPOSE 3000`)** に切り替える。差分はそのまま適用できる形で以下に示す。

`Dockerfile` (末尾 3 行を変更):

```diff
- # Start server via Thruster by default, this can be overwritten at runtime
- EXPOSE 80
- CMD ["./bin/thrust", "./bin/rails", "server"]
+ # Start server directly via Puma (Thruster を外した。docs/ops/deployment.md 3.1 節)
+ EXPOSE 3000
+ CMD ["./bin/rails", "server"]
```

`Gemfile` (該当行を削除):

```diff
- # Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
- gem "thruster", require: false
-
```

`bin/thrust` を削除する:

```bash
git rm bin/thrust
```

`Gemfile.lock` を更新する (DB 接続不要、`bundle install` のみ)。Dockerfile は Ruby ではないので `bin/rubocop` の対象から外す。

```bash
export MISE_TRUSTED_CONFIG_PATHS=/home/debian/tsumikura
mise x -- bundle install
mise x -- bin/rubocop --cache false Gemfile
```

コミットして再度 push する。Dockerfile デプロイでは `EXPOSE` からの自動マッピングが `http:3000:3000` になり、外部の 80/443 番へのマッピングが無いままになる (letsencrypt の HTTP-01 チャレンジも失敗する) ので、**push の後に明示的にポートを設定する**。

```bash
git push dokku phase-5-dokku-deploy:main   # あるいはその時点の作業ブランチ
dokku ports:set tsumikura http:80:3000
dokku ports:report tsumikura
# => "Ports map: http:80:3000" が出ること
```

証明書を入れた後に切り替える場合は `https:443:3000` も追加する。

```bash
dokku ports:set tsumikura http:80:3000 https:443:3000
```

(案 A に切り替えた場合は) [デプロイ構成](deployment.md#31-thruster-をどうするか-決定済み-残す) の 3.1 節と [未決事項](../plan/open-questions.md) の決定済みを書き換える (12 節参照)。**2026-09-21 の初回デプロイでは切り替えなかった。**

**参考: 既存の Dokku 上の Rails アプリの構成を見る**

```bash
dokku apps:list
dokku ports:report <既存アプリ名>
```

既存アプリが Thruster を使っているか (`EXPOSE 80`)、Puma 直起動か (`EXPOSE 3000` など) を比べる材料になる。可能なら該当アプリのリポジトリの `Dockerfile` も見比べる。

## 7. Let's Encrypt の有効化

> **既存の Dokku 環境では**: 他のアプリで既に Let's Encrypt を使っていると、**通知先メールアドレスが global に設定済み**で、**自動更新の cron も登録済み**のことが多い。その場合は該当の手順を飛ばす。まず確認する。
>
> ```bash
> dokku config:get --global DOKKU_LETSENCRYPT_EMAIL   # 値が出れば global に設定済み (アプリ側の set は不要)
> dokku letsencrypt:cron-job                          # 自動更新の cron が登録済みか
> dokku letsencrypt:list                              # 既存アプリの証明書の一覧 (サブコマンドの有無は dokku letsencrypt:help で確認)
> ```
>
> 2026-09-21 の初回デプロイでは既存環境の設定があったので、`letsencrypt:enable` だけを実施した。

**デプロイが成功し、かつ `$APP_HOST` の DNS が反映されてから実行する** (1 節の `dig +short $APP_HOST` で確認する)。証明書の発行に失敗する状態で繰り返し試すと Let's Encrypt のレート制限に掛かるので、うまくいかないときは原因を確認してから再試行する。

```bash
dokku letsencrypt:report tsumikura --letsencrypt-email   # 空なら次を実行 (global に設定済みなら不要)
dokku letsencrypt:set tsumikura email <通知を受け取るメールアドレス>
dokku letsencrypt:enable tsumikura
```

自動更新用の cron が未登録なら追加する。

```bash
dokku letsencrypt:cron-job          # 状態を表示する
dokku letsencrypt:cron-job --add    # 未登録なら実行する
```

**確認事項**: `letsencrypt:set` サブコマンドが無い古いプラグインでは `dokku config:set --no-restart tsumikura DOKKU_LETSENCRYPT_EMAIL=<メールアドレス>` 方式になる。`dokku letsencrypt:help` で `letsencrypt:set` の有無を確認する。

## 8. 初回管理者の作成

```bash
dokku run tsumikura bin/rails tsumikura:create_admin \
  ADMIN_EMAIL=admin@example.com ADMIN_NAME=かんりしゃ
```

自動生成されたパスワードが標準出力に **1 度だけ** 表示される。その場で控える。`ADMIN_PASSWORD=...` で明示的に指定することもできるが、シェルの履歴 (`.bash_history`) と `ps` に平文で残るので使わない。

## 9. 動作確認チェックリスト

```bash
# /up が 200 を返す
curl -s -o /dev/null -w '%{http_code}\n' https://$APP_HOST/up
# => 200

# healthcheck の状態を確認する
dokku checks:report tsumikura

# http -> https のリダイレクトは Dokku の nginx が行う (証明書発行後のみ)。アプリ自身は assume_ssl
# により常に https とみなすので、自分でリダイレクトは返さない。/up はコンテナ直アクセス用の除外な
# ので、外部からの確認は / など別のパスで行う。
curl -sI http://$APP_HOST/
# => HTTP/1.1 301 Moved Permanently 相当のヘッダと Location: https://... が出る

# Solid Queue の supervisor が Puma と一緒に起動している
dokku logs tsumikura -n 200 | grep -i 'solid queue'

# /cable はマウントされていない (config.action_cable.mount_path = nil)
curl -s -o /dev/null -w '%{http_code}\n' https://$APP_HOST/cable
# => 404
```

ログインとセッション Cookie の確認は、ブラウザの DevTools (Chrome の Application タブ / Firefox の Storage タブ) で `session_id` Cookie の `Secure` / `HttpOnly` / `SameSite` 列を見るのが最も確実で簡単 (パスワードもシェル履歴に残らない)。curl で確認したい場合は CSRF トークンの取得が要るので (単純な `curl -X POST` は `422` になる)、次のように差し替える (レイアウトに `csrf_meta_tags` があることを確認済み。`app/views/layouts/application.html.erb` を変更した場合は再確認する)。

```bash
JAR=$(mktemp)
TOKEN=$(curl -s -c "$JAR" https://$APP_HOST/session/new | grep -o 'name="csrf-token" content="[^"]*"' | sed 's/.*content="//; s/"$//')
read -rsp 'password: ' PW; echo
curl -sD - -o /dev/null -b "$JAR" https://$APP_HOST/session \
  --data-urlencode "authenticity_token=$TOKEN" \
  --data-urlencode 'email_address=admin@example.com' \
  --data-urlencode "password@"<(printf %s "$PW") | grep -i '^set-cookie: session_id'
unset PW; rm -f "$JAR"
# => session_id=...; path=/; expires=...; secure; HttpOnly; SameSite=Lax
```

- [ ] `/up` が 200、`dokku checks:report tsumikura` も正常
- [ ] `http://$APP_HOST/` が https へ 301 リダイレクトされる (Dokku の nginx。証明書発行後)
- [ ] ログインできる
- [ ] `session_id` Cookie に `Secure` / `HttpOnly` / `SameSite=Lax` が付く
- [ ] `dokku logs tsumikura -n 200` に Solid Queue の supervisor 起動ログが出る
- [ ] `/cable` が 404

**トラブルシュート**: ログイン前を含め全ページが 403 (Blocked hosts) になる場合は、`APP_HOST` が空文字で設定されていないか確認する。

```bash
dokku config:get tsumikura APP_HOST
```

## 10. DB バックアップの設定

> **既存の Dokku 環境では**: 他のサービスで既にバックアップを回していると、**S3 の認証情報や保存先の決め方が既にある**ことが多い。その場合は下の `backup-auth` を既存の設定に合わせる (バケット名・region・エンドポイント URL を既存のものと揃える)。`backup-auth` は**サービスごと**の設定なので、`tsumikura-db` にも改めて実行する必要がある。既存サービスでの設定の仕方は次で確認する。
>
> ```bash
> dokku postgres:list                                   # 既存のサービス名
> dokku postgres:backup-schedule-cat <既存のサービス名>   # 既存のスケジュール (バケット名や cron 式の書き方の見本になる)
> dokku postgres:help                                   # backup-auth に渡せる引数を確認する
> ```
>
> 認証情報そのものを読み出すコマンドは無い (設定済みかどうかは `backup-auth` を実行し直して上書きするのが確実)。2026-09-21 の初回デプロイでは既存環境の設定に合わせて実施した。

**初回デプロイと同時に設定する** (後回しにしない)。認証情報はシェル履歴に残さないよう `read -rs` で受け取る。

```bash
read -rsp 'S3 access key: ' AWS_ACCESS_KEY_ID; echo
read -rsp 'S3 secret key: ' AWS_SECRET_ACCESS_KEY; echo
dokku postgres:backup-auth tsumikura-db "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
dokku postgres:backup-schedule tsumikura-db "0 4 * * *" <bucket>
```

AWS 以外の S3 互換ストレージを使う場合は region・署名方式・エンドポイント URL も渡す (`backup-auth` の追加引数)。

```bash
dokku postgres:backup-auth tsumikura-db "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" <region> s3v4 <endpoint-url>
```

「バックアップが 1 回取れている」ことを確認する。

```bash
dokku postgres:backup tsumikura-db <bucket>       # 手動で 1 回実行する
dokku postgres:backup-schedule-cat tsumikura-db   # スケジュールの設定内容を確認する
```

S3 互換の保存先を用意していない場合は、`dokku postgres:export` を cron で回す方式に切り替える ([デプロイ構成](deployment.md#8-バックアップと復旧))。`<bucket>` は実際の値に置き換える。

## 11. ロックアウト時の復旧

管理者がパスワードを忘れた場合:

```bash
dokku run tsumikura bin/rails tsumikura:create_admin \
  ADMIN_EMAIL=<その管理者のメールアドレス> ADMIN_RESET_PASSWORD=1
```

新しいパスワードが標準出力に 1 度だけ表示され、そのユーザーの既存セッションはすべて失効する。管理者が 1 人も居ない、または対象が無効化されている場合は、別のメールアドレスで新しい管理者を作る ([デプロイ構成](deployment.md#8-バックアップと復旧))。

## 12. 終わったら

決めたことを反映する。**2026-09-21 の初回デプロイぶんは反映済み。**

- **Thruster**: 案 B (残す) で確定。[デプロイ構成](deployment.md#31-thruster-をどうするか-決定済み-残す) の 3.1 節と [未決事項](../plan/open-questions.md) に反映済み。
- **PostgreSQL のメジャーバージョン**: 18 で `compose.yaml` と一致していたので変更なし (2 節)。
- [実装計画](../plan/implementation-plan.md) の Phase 5 は「サーバ側も完了 (2026-09-21)」に更新済み。
- **まだ残っていること**は [未決事項](../plan/open-questions.md) の「残作業」を見る (PWA のホーム画面追加、日次ダイジェスト、iPhone / iPad の通知とパスキー、GitHub Actions の初回実行など)。

## 確認事項 (Dokku の挙動として確信が持てなかった点)

- `dokku letsencrypt:set` サブコマンドの有無 (プラグインのバージョンに依存する可能性がある。無ければ `dokku config:set --no-restart tsumikura DOKKU_LETSENCRYPT_EMAIL=...` 方式。`dokku letsencrypt:help` で確認する) (7 節)
- `dokku storage:ensure-directory` の `--chown` オプションの有無 (無ければ従来の `sudo chown -R 1000:1000 <パス>` で代替する) (4 節)
- dokku-postgres プラグインが PostgreSQL 18 のデータディレクトリ変更 (`/var/lib/postgresql` への変更) に対応しているか (`grep -n PG_MAJOR /var/lib/dokku/plugins/available/postgres/functions` で確認する) (2 節)
- Dokku サーバの Docker が 20.10 以降か (1 節の `docker version` で確認する。それより古いと非 root ユーザーでの 80 番 bind に失敗する可能性がある) (6 節)
- `dokku git:set tsumikura deploy-branch main` が確実に効くか (`dokku git:report tsumikura` で "Git deploy branch" を確認する) (2 節)
