# 未決事項とリスク

[実装計画](implementation-plan.md) / [概要](../spec/00-overview.md) / [デプロイ](../ops/deployment.md)

## 1. 残作業 (v1 の実装は完了。実行・差し替えだけが残っている)

全 13 フェーズの実装とテストは終わっている。ここに残るのは**この環境では実行できなかったこと**で、
コードの不足ではない。上から順に消していくと v1 の運用が始められる。

**2026-09-21 に Dokku へデプロイして動作確認した** (`phase-13-passkeys` を `git push dokku phase-13-passkeys:main`。
GitHub にはまだ push していない)。済んだものは「済」と日付を残す。

| # | 残作業 | 状況 | 何をするか | どこを見るか |
|---|---|---|---|---|
| A | **GitHub Actions の初回実行** | **残** | リポジトリを push して CI を 1 回通す。`ruby/setup-ruby` が `.ruby-version` の 4.0.7 を取得できるかはここで初めて分かる。取得できなければ利用可能な最新パッチに下げる | [開発環境](../ops/development.md#8-ci) / 下の「決定済み」 |
| B | **`js: true` の system spec の CI 初回実行** | **残** (12 件が未実行のまま) | 実ブラウザの system spec (初期パスワードの表示など) は手元では Chrome を用意できていない。CI で初めて走るので、最初の 1 回は結果を確かめる。落ちたら `config/ci.rb` と `.github/workflows/ci.yml` の artifact の取り回しを見る | [開発環境](../ops/development.md#8-ci) |
| C | **Dokku 初回デプロイ** | **済 (2026-09-21)** | predeploy (`db:prepare`) と `/up` のヘルスチェックはどちらも成功。Thruster は変更なしで動いた (未決 #1 を決定済みに移した)。PostgreSQL は 18 で `compose.yaml` と一致 | [初回デプロイ手順書](../ops/first-deploy.md) |
| C2 | **HTTPS とログインまわりの確認** | **済 (2026-09-21)** | Let's Encrypt の発行、http → https のリダイレクト、`session_id` Cookie の `Secure` / `HttpOnly` / `SameSite=Lax`、管理者の作成、ログイン、家族アカウントの追加 (初期パスワードの 1 度だけの表示)、品目とマスタ、購入の記録、使用の入力、棚卸、廃棄、買い物リスト。**本番のブラウザで JS のエラーが出ないことも確認済み** (importmap も Stimulus も正常。ワンタップ使用のトースト・取り消し・約 8 秒での自動消去、入数 × パック数の切り替え、チェック時のスクロール維持まで期待どおり) | [初回デプロイ手順書 9 節](../ops/first-deploy.md#9-動作確認チェックリスト) |
| D | **パスキーの実機確認** | **一部済 (2026-09-21)** | **PC は済**: 登録でき、「パスキーでログイン」ボタンもメール欄の入力候補 (conditional UI) も動いた。**残: iPhone / iPad (Safari のユーザー操作要件を含む)、Android**。**下の注意も読むこと** | [認証](../spec/05-auth.md#実機での確認手順-https-の本番環境で) |
| E | **Web Push の実機確認** | **一部済 (2026-09-21)** | **Android は済**: VAPID 鍵を設定して購読でき、テスト送信が届き、通知のタップでアプリが開いた。**残: iPhone / iPad、PC ブラウザ、毎朝 8 時の日次ダイジェスト (まだ朝をまたいでいない)** | [通知](../spec/04-notifications.md#7-実機でしか確かめられないこと) / [初回デプロイ手順書 3.1](../ops/first-deploy.md#31-vapid-鍵-web-push) |
| E2 | **ホーム画面への追加 (PWA)** | **残** | manifest の `icons` を差し替えたので、Android / iOS で「ホーム画面に追加」してアイコンが「つ」のものになることを見る (iOS の通知はこれが前提) | [通知](../spec/04-notifications.md#1-pwa-の有効化) |
| E3 | **予測表示の確認** | **残** | ダッシュボードと品目詳細の予測は、使用履歴がたまってから確かめる (いまは `unknown` が多いのが正しい) | [予測](../spec/02-forecast.md) |
| F | **アイコンの差し替え** | **済 (2026-09-21)** | `public/icon.svg` を原本に、`script/generate_icons.sh` が 512 / 192 / maskable / apple-touch の PNG を作る。manifest と `<link rel="apple-touch-icon">` も差し替え済み | 下の「決定済み」 |
| G | **バックアップの設定** | **済 (2026-09-21)** | 既存の Dokku 環境の設定に合わせて実施した。Solid Queue の起動ログも確認済み | [初回デプロイ手順書 10 節](../ops/first-deploy.md#10-db-バックアップの設定) |
| H | **VAPID 鍵の退避** | **済 (2026-09-21)** | 手元で生成して退避したうえで `dokku config:set` した (下の決定済み #7 のとおり) | [初回デプロイ手順書 3.1](../ops/first-deploy.md#31-vapid-鍵-web-push) |

### パスキーの実機確認で特に見るところ

**パスキーの JavaScript はこの環境で一度も実行していない** (node が無く、`js: true` の system spec も
パスキーは扱っていない)。最初の 1 回は次の順で確かめる。

1. ログイン画面と `/account` をブラウザで開き、**コンソールに import エラーが出ていない**ことを見る
   (`passkey_codec` の importmap の pin が効いているか。`Failed to resolve module specifier` が出たら
   `config/importmap.rb` と `bin/importmap json` を疑う)。
2. **旧ブラウザ用のフォールバック経路は未検証。** `PublicKeyCredential.parseCreationOptionsFromJSON` /
   `parseRequestOptionsFromJSON` / `credential.toJSON()` を持たないブラウザでは自前の base64url 変換に
   落ちるが、その経路を実際に通したことはない (新しい Safari / Chrome はどれも持っている)。
   古い端末で登録できないときは、ここを最初に疑う。
3. **Safari は `navigator.credentials.create` をユーザー操作の直後に呼ぶことを求める。**
   登録はパスワード確認の `fetch` を 1 回挟んでから `create` を呼ぶので、
   Safari が「ユーザー操作から離れすぎ」と見なして `NotAllowedError` にする可能性がある。
   実機でしか分からない。もし弾かれるなら、challenge を先に取っておく (画面を開いた時点で
   パスワードを確かめる) 形に組み替える。
4. user verification を必須にしたので、**PIN を設定していないセキュリティキーは登録時に PIN の設定を
   求められる**。これは仕様どおり。

### パスキーの `js: true` system spec について

実ブラウザでのパスキーの spec は **Chrome DevTools Protocol の Virtual Authenticator**
(`WebAuthn.addVirtualAuthenticator`) が要る。Capybara / Selenium から CDP を叩く設定と、
認証器の状態をテストごとに作り直す後始末が必要で、得られるものの割にセットアップが重い。

v1 では **request spec (`WebAuthn::FakeClient`) で検証ロジックを固定**し、ビューについては
Stimulus の `data-*` 属性とボタンが出ていることを request spec で守っている。
実ブラウザでの確認は上の D (実機確認) で代替する。

運用を始めてパスキーまわりを触ることが増えたら、Virtual Authenticator の system spec を足す。

## 2. 未決 (決めるタイミングが来たら決める)

番号は振り直さない (他の文書から参照されているため)。決まったものは下の「決定済み」へ移し、
そこに「旧 #N」と書いてある。いま欠番なのは #1 / #10 / #12 / #13。

| # | 項目 | リスク / 論点 | 推奨 | 決めるフェーズ |
|---|---|---|---|---|
| 2 | **通知の配信時刻** | 朝 8 時が家庭の生活リズムに合うか不明 | 既定は `config/tsumikura.yml` の `digest_hour: 8`。`config/recurring.yml` を書き換えて再デプロイすれば変えられる。画面からの変更は v2 | 12 |
| 3 | **`unknown` の UI 表現** | 「判定できません」が多いと不安になる | バッジは「—」、詳細に「データ収集中 — 使用記録がたまると予測を開始します」と出す。ダッシュボードの要購入件数には含めない | 10 |
| 4 | **消費ペースの直近重視** | 単一窓の単純平均は、生活パターンの変化への追随が遅い | v1 は単一窓のまま運用する。追随が悪ければ短期窓・長期窓の合成に差し替える (`Forecast::Calculator` が PORO なので spec の追加だけで検証できる) | 運用後 |
| 5 | **RuboCop と `app/models/forecast/`** | `rubocop-rails-omakase` が Phase 3 で追加する `app/models/forecast/` (PORO) に予期せぬ指摘を出す可能性がある (`spec/` 側は Phase 2 で確認済み。下記決定済み参照) | Phase 3 で `bin/rubocop` を通し、必要なら `.rubocop.yml` に最小限の除外を追加する。`.rubocop_todo.yml` は作らない | 3 |
| 6 | **在庫単位の表記ゆれ** | 「本」「ほん」「Pcs」が混在しうる | `items.unit` は string の自由入力のままにし、よく使う候補 (個 / 本 / ロール / 袋 / パック / 箱 / 枚 / セット) をサジェストする。マスタ化はしない | 6 |
| 7 | **VAPID 鍵のバックアップ** | 鍵を失うと全購読が無効になり、家族全員が再購読することになる | **手元で生成してからパスワードマネージャ等へ退避し、そのあと `dokku config:set` する** (サーバに生成させない)。手順は [初回デプロイ手順書 3.1 節](../ops/first-deploy.md#31-vapid-鍵-web-push)。`dokku config:show` からも復元できるが、アプリを作り直すと失われる | 12 |
| 8 | **Dokku 上での migration 失敗** | `app.json` の predeploy が落ちるとデプロイが止まる (正しい挙動) | 破壊的 migration は 2 段階デプロイ (カラム追加 → コード変更 → 旧カラム削除) にする。家庭用なので通常は不要だが、方針として明記しておく | 随時 |
| 9 | **`json` gem を 3 未満に固定している** | json 3 は `JSON.parse` のオプションをキーワード引数でしか受けないが、ActiveSupport 8.1.3.1 はハッシュを位置引数で渡す。固定しないと spec が 70 件落ちる。固定したままだと json 3 の修正・改善を取りこぼす | `Gemfile` の `gem "json", "< 3"` を維持する。**Rails を更新したらこの行を外して `bin/rspec` を流し**、通るなら固定を解除する ([実装計画](implementation-plan.md) 付録 A) | Rails 更新時 |
| 11 | **確定済みの棚卸の取り消し** | 棚卸のマイナス差分は `counted_on` の 1 日に全量が消費として計上されるので、打ち間違い (12 を 1 と入れる) はそのまま予測に残り続ける。いまは確定済みの棚卸を取り消す手段が無く、直すには逆向きの棚卸をもう 1 回するしかない | Phase 9 では**確認画面で大きく減る差分に注意の印**を出して入力時に気づかせる (`StockTakeEntry#large_decrease?`: 記録在庫の半分以上かつ 2 以上の減少)。取り消し機能は、実運用で打ち間違いが起きてから検討する (movement をまとめて消して再計算するだけなので、あとからでも足せる) | 運用後 |
| 14 | **購読の再同期が `/account` でしか働かない** | Push サービス側で購読が作り直されると (`pushsubscriptionchange`)、次に `/account` を開くまで通知が止まる。1 日 1 通なので、止まっていることに気づきにくい | 今は割り切る (Service Worker からは新しい購読をサーバへ送れない)。気になったら、購読の再同期だけをレイアウト常駐の小さな Stimulus controller に出して全ページで走らせる。[通知](../spec/04-notifications.md#5-割り切っていること) | 運用後 |

## 3. 決定済み (理由を残す)

| 項目 | 決定 | 理由 / 参照 |
|---|---|---|
| **主キーの型** | **アプリの全テーブルを UUIDv7 (`uuid` 列 + 既定値 `uuidv7()`)。Solid Queue / Solid Cache は bigint のまま** | Rails 既定の連番 id は URL に出ると予測可能で、`/items/1`〜`/items/50` をたどれば登録件数も他の品目も見えてしまう。生成を DB の既定値に置くと `insert_all` / `upsert_all` や生 SQL でも同じ規則になり、振り忘れの穴ができない。**PostgreSQL 18 以上が必須**になる。Solid Queue / Cache を除いたのは (1) id が外に出ない (2) Solid Queue は `job_id` の昇順で FIFO を決める (3) gem のスキーマ更新と食い違う、の 3 つ。[データモデル 2 節](../spec/01-domain-model.md) |
| **UUID の生成を Ruby 側でしない** | **DB の既定値 `uuidv7()` に任せる** | Ruby 側 (`before_create` や `SecureRandom.uuid_v7`) だと、モデルを経由しない書き込み (`insert_all` / `upsert_all` / 生 SQL / migration) のたびに振り忘れの穴ができる。代償として PostgreSQL 18 が必須になるが、開発・CI・本番のすべてをそろえられる見込みが立っている |
| **URL の id の表現** | **Base58 の 22 文字 (固定長)。生の UUID は URL では受け付けない** | 36 文字の UUID は URL が長く読みにくい。Base58 は `0` `O` `I` `l` を除くので写し間違えにくく、ASCII 昇順のアルファベットなので辞書順が UUID の大小と一致する。長さを 22 に固定するのは、可変長だと 1 つの UUID に複数の表現ができて URL が一意にならないため。生の UUID も受け付けると入口が 2 つになるので、22 文字の Base58 以外は 404 にする。[画面 3 節](../spec/03-screens.md) |
| **POST の本文に入る id** | **UUID のまま** | URL に出ないので短くする理由がない。Base58 にすると `where` に渡す前に必ずデコードが要る。セレクトの値・hidden・`counts[<id>]` や `purchase[lines][<id>]` のようなキーが対象 |
| **UUIDv7 から作成時刻が読めること** | **許容する** | 先頭 48 ビットがミリ秒のタイムスタンプなので、URL から作成時刻は分かる。隠したいのは「件数と他のレコード」で、作成時刻は画面にも出ている。完全ランダム (v4) にすると、index の局所性が落ちて挿入順の tie-break も使えなくなる |
| **主キーの変換 migration** | **作らない。DB を作り直す** | 開発 DB も本番 DB も動作確認用で捨ててよい段階だったので、既存の `create_table` を直接書き換えた。本番の作り直し手順は [デプロイ 10 節](../ops/deployment.md#10-スキーマを作り直す-主キーの-uuidv7-化) |
| **挿入順が要るところの並び** | **`order(:created_at, :id)`** | `uuidv7()` は同一バックエンド内では単調増加だが、**別の接続どうしの同一ミリ秒内では順序を保証しない**。ロックの順序 (デッドロック防止) は「一貫した全順序」であればよいので `order(:id)` のままでよい |
| **Thruster を残すか外すか** (旧 #1) | **残す (案 B)。`Dockerfile` / `Gemfile` / `bin/thrust` は変更しない** (2026-09-21 に Dokku で確認) | 初回デプロイで現状の Dockerfile のまま動いた。`listen tcp :80: bind: permission denied` も 502 も出ず、`EXPOSE 80` からの自動検出だけで済んだ (`ports:set` の明示も不要)。案 A (外して Puma 直起動) の切り替え手順は「参考 (使わなかった)」として [デプロイ](../ops/deployment.md#31-thruster-をどうするか-決定済み-残す) 3.1 節と [初回デプロイ手順書](../ops/first-deploy.md#6-thruster-の判断-決定済み-案-b) 6 節に残してある |
| **本番の PostgreSQL のメジャーバージョン** | **18。`compose.yaml` は変更しない** (2026-09-21 に確認) | dokku-postgres が作ったサービスが 18 で、開発用 `compose.yaml` の `postgres:18` と一致していた |
| **パスワードの最小長** (旧 #10) | **12 文字** (`User::MINIMUM_PASSWORD_LENGTH`。2026-09-21 に 8 から引き上げ) | 公開インターネットに出したので、NIST SP 800-63B の**下限**である 8 文字のままにしない。常用手段がパスキーに移って手入力の機会が減ったので、長くしても実害が小さい。**検証は `allow_nil` でパスワードを設定・変更するときだけ走る**ので、引き上げ前の短いパスワードのユーザーはそのままログインでき、パスワード以外の属性も更新できる (再設定は強制しない)。管理者が発行する生成パスワード (19 文字) と `tsumikura:create_admin` の自動生成は影響なし。[認証](../spec/05-auth.md#パスワードの要件) |
| **PWA のアイコン画像** (旧 #12) | **`public/icon.svg` を原本に、`script/generate_icons.sh` が PNG を生成する。デザインを変えるときは `icon.svg` を直してスクリプトを実行し直す** | 生成物は `icon.png` (512px・角丸) / `icon-192.png` (192px) / `icon-maskable.png` (512px・全面塗り・安全域に収めた) / `apple-touch-icon.png` (180px・全面塗り)。manifest は **`any` と `maskable` を別エントリ**にする (兼ねさせると Android の円形の切り抜きで端が欠ける)。通知のアイコンは 192px を使い、`badge` は単色のシルエット画像が要るので付けない。スクリプトは使い捨ての Docker コンテナ (rsvg-convert) で描くので、開発機に画像ツールを入れなくてよい。[通知](../spec/04-notifications.md#1-pwa-の有効化) |
| **ログアウトしたときに、その端末の購読を消すか** (旧 #13) | **消す。ただし「メニューのログアウト」だけ** | 共用の端末を使ったあと、ログアウトしたのに通知が届き続けるのに気づきにくい。`logout_controller.js` が `submit` を横取りして端末側の購読を解除し、`endpoint` を hidden で送る。サーバは `Current.user` の一致する購読だけを消す。**どの段階で失敗してもログアウトは進める** (未対応・未登録・例外・2 秒のタイムアウト)。JS の無い環境、「このデバイス以外をすべてログアウト」、別端末からのセッションの個別失効では購読は残る (セッションと購読を紐づけていないため)。[通知](../spec/04-notifications.md#5-割り切っていること) |
| **Ruby 4.0.7 の CI 可用性** | **`.ruby-version` は 4.0.7 のまま。GitHub Actions の初回実行で最終確認** | `ruby/setup-ruby` が参照する `ruby-builder-versions.json` に `4.0.7` が載っていることは確認した (2026-09-19)。`@v1` タグで実際に取得できるかは CI の初回実行で確かめる。取得できなければ利用可能な最新パッチに下げる。[開発環境](../ops/development.md#8-ci) |
| **RuboCop と `spec/` ディレクトリ** | **除外設定は不要** | Phase 2 で追加した `spec/` 一式 (support / requests / system) を含め `bin/rubocop` が 32 ファイル・0 件で通った。`.rubocop.yml` は変更していない |
| **Tailwind インストーラの出力先** | **レイアウト変更不要。`stylesheet_link_tag :app` のまま** | レイアウトに既に `:app` があったため、インストーラは別枠のタグを追加しなかった。`Tailwindcss::Engine` が `app/assets/tailwind` (ソース) を `assets.excluded_paths` に加えるので、`:app` が拾うのはビルド成果物の `app/assets/builds/tailwind.css` だけ。[開発環境](../ops/development.md#5-tailwind-css) |
| **Solid Cable** | **削除する** | リアルタイム同期は不要と決めた。画面の即時反映は Turbo Stream レスポンスで足りる。既定の `polling_interval: 0.1` の DB ポーリングを共有 Postgres に掛ける割に合わない。`config/cable.yml` は `adapter: async` (実質未使用)。[デプロイ](../ops/deployment.md#11-solid-cable-を削除する-確定) |
| **ログイン ID** | **メールアドレスのまま** | Rails 8 の認証ジェネレータの既定をそのまま使う。メールは送らないので実在アドレスである必要はない。パスワード忘れは管理者が再設定する。[認証](../spec/05-auth.md) |
| **在庫切れ予測日の起点** | **最後の消費イベント日 (anchor)** | 今日起点だと、使わない日が続くほど予測日が後ろへずれる。また在庫 = 未使用数なので、使用中の 1 個を `+1` 回分として数える必要がある。[予測](../spec/02-forecast.md#5-在庫切れ予測日-need_by_on) |
| **集計窓** | **最低 90 日、直近 5 件目の消費イベント日まで自動で伸長、上限 730 日** | 年 1〜2 回しか使わない品目を固定 90 日窓で見ると永久に判定できない。窓が伸びるので interval モードは不要 |
| **集計窓の端** | **半開区間 `(window_start, today]`。窓の開始が消費イベント日で決まったときは、観測日数を `anchor − window_start` とする** | 開始日のイベントは間隔の始点なので消費量に数えない (数えると 5 件 ÷ 4 間隔でペースが過大になる)。最後の消費から今日までの空白は未完の間隔なので分母に入れない (入れると次の使用が近づくほどペースが過小になる)。判定に必要な消費イベント 2 件は開始日を含めて数える。[予測](../spec/02-forecast.md#3-集計窓) |
| **消費イベントの数え方** | **消費のあった日を 1 件と数える** | 1 回の使用が FEFO で複数行に分かれても、同じ日に何度記録しても 1 件。行数で数えると窓の伸び方と判定条件が記録の仕方に左右される |
| **manual モードの起点** | **最後の消費イベント日。無ければ最初の在庫イベント日 (`tracking_started_on`)** | `today` を起点にすると、使用記録が無い間は予測日が毎日後ろへ逃げて近づかない |
| **none モードの在庫 0** | **`urgent` にしない (最低在庫数だけで判定)** | none は予測させないという意思表示。在庫 0 を知らせたい品目には最低在庫数 1 を設定する |
| **未来の日付の記録** | **不可 (バリデーション)** | 消費イベントが今日以前にあることを予測が前提にしている。過去日は自由に入力できる |
| **期限切れロットの引き当て順** | **FEFO の最後に回す** | 要購入判定の在庫は期限切れロットを除いて数えるので、期限切れから先に引くと使っても在庫が減らない。期限切れのものを使ったときはロットを手動で選ぶ |
| **予測モード** | **auto / manual / none の 3 つだけ** | 使用間隔を別モードで持つ interval モード、月あたりペースの手入力、品目ごとの窓日数の設定は設けない。manual は `manual_interval_days` (1 単位を何日で使うか) だけを持つ |
| **在庫 0 の扱い** | **ペースが分かっていれば通常の式どおり。ペース不明のときだけ urgent** | くん煙剤を使い切った直後から半年間「購入推奨」が出続けるのを防ぐ |
| **最低在庫数の境界** | **`q < minimum` で urgent、`q == minimum` で soon** | 「この数は切らしたくない」という意味なので、ちょうどの時点ではまだ切らしていない |
| **要購入判定の在庫数** | **期限切れロットの残数を除く** | 期限切れの保存食を備蓄に数えない |
| **消費に数えるもの** | **使用 + 棚卸のマイナス差分のみ** | 廃棄は「使った」ではないので含めない (含めるとペースが過大になり買いすぎる)。購入・プラス差分も含めない |
| **在庫の数量型** | **整数固定** | 単位を「本 / 袋 / ロール」で表現して回避する。将来必要なら `decimal(10,2)` へ移行 (migration 1 本) |
| **「使用開始」と「使い切り」** | **区別しない。使用開始時点で在庫から引く** | 在庫 = 未使用数。「開封中」を数えたくなったら `lots` に `opened_quantity` を足す |
| **在庫超過の使用記録** | **エラーにせず、`kind: adjustment` のロットを自動で作って補う** | 1 タップ記録が失敗すると家族が使わなくなる。調整プラスは消費ペースに入れないので予測は歪まない |
| **記録の削除制限** | **原則として制限しない。ただし使用・廃棄が紐づくロットは削除不可、残数が負になる数量編集はエラー** | 在庫は総和方式なので現在庫は必ず正しくなる。台帳の整合性が壊れるケースだけを禁じる |
| **棚卸より前の日付への記録追加** | **警告するがブロックしない** | 現在庫は正しく減る。「その日の在庫」は元々再現しない割り切り |
| **同時操作の競合** | **`item.lock!` による行ロックのみ。楽観ロックは入れない** | 追記型なので通常は問題にならない |
| **セッションの有効期限** | **Rails 既定の permanent cookie のまま** | 家庭用でスマホから再ログインさせたくない。代わりに `/account` にデバイス一覧と個別失効を用意する |
| **パスキーのみのユーザー** | **許さない (パスワードは常に必須)** | デバイス紛失時に完全ロックアウトされる。管理者が再発行できる退路を残す |
| **管理者が 1 人の状態** | **最後の管理者の降格・無効化をバリデーションで禁止** | 復旧手段として `tsumikura:create_admin` をサーバで実行できるようにする |
| **マスタ (カテゴリ/保管場所/店舗) の削除** | **nullify** | 外部キーは `on_delete: :nullify`、モデルは `dependent: :nullify`。削除前に「n 件の品目から外れます」と確認する |
| **品目の削除** | **物理削除しない (`archived_at`)** | `dependent: :destroy` で全記録が消えるため、UI からはアーカイブのみ提供する |
| **ユーザーの削除** | **無効化のみ (`deactivated_at`)** | 記録の入力者としての参照が残る |
| **調整ロットの価格** | **NULL のまま。単価の平均から除外する** | 価格 NULL のロットを混ぜると平均単価が実態とずれる。一覧では「調整」バッジで区別する |
| **JAN バーコード** | **今は持たない** | 必要になったら migration 1 本で `items.jan_code` を足せる。先回りしてスキーマを汚さない |
| **品目の写真** | **v1 スコープ外** | Active Storage + 永続ストレージが必要。マウントの手順だけ [デプロイ](../ops/deployment.md) に残す |
| **iOS の Web Push** | **「ホーム画面に追加」が必須と案内する** | ブラウザ側の制約で回避不能。`/account` で iOS を検出して案内を出す。[通知](../spec/04-notifications.md#6-ios-の制約) |
| **`solid_queue:update` の運用** | **生成された `db/queue_schema.rb` は残さず、差分を migration に手で取り込む** | 単一 DB 構成と食い違うため。手順は [デプロイ](../ops/deployment.md#13-gem-アップデート時の運用-solid_queueupdate) |
| **バックアップ** | **Phase 5 のデプロイと同時に設定する** | 家族の記録が消えると復旧不能。後回しにしない |
| **パスキーの user verification** | **必須にする** (`user_verification: "required"` + `verify(..., user_verification: true)`) | 査読で指摘。パスキー 1 つでログインできる = 単独要素なので、`preferred` だと「持っているだけ」で入れてしまう (PIN 無しの USB セキュリティキーを拾って挿すだけ)。FakeClient で `user_verified: false` の assertion が `preferred` では通ることを実測した。代償として、PIN を設定していないセキュリティキーは登録時に PIN の設定を求められる |
| **challenge の 1 回限りの担保** | **有効期限 (登録 5 分 / 認証 15 分) + `Rails.cache` への消費記録 (SHA256 ダイジェスト、`unless_exist`)** | 査読で指摘。セッションが CookieStore なので `session.delete` は「次の Cookie から消す」だけで、古い Cookie はサーバから見ると永久に有効。`sign_count` を常に 0 で返す同期型のパスキーでは、Cookie と assertion の組を送り直すだけで何度でもログインできてしまう。登録側では、生体認証のキャンセルで残った challenge を盗まれるとパスワードの再確認を迂回できる |
| **パスキー登録時のパスワード再確認** | **必須にする** (`POST /passkeys/options` で `user.authenticate` を通ったときだけ challenge を出す) | 仕様 (05-auth.md) に定めが無かったので Phase 13 で決めた。セッションを盗んだ者が自分のパスキーを足すと、**パスワードを変えても居座れる** (パスキーはパスワード変更で失効しない)。challenge を出す前に確かめるので、生体認証のダイアログの前に間違いが分かる。challenge が無ければ `POST /passkeys` は必ず失敗するので、確認は 1 か所で足りる |
| **登録用と認証用の challenge のセッションキー** | **必ず分ける** (`:passkey_registration_challenge` / `:passkey_authentication_challenge`) | 同じキーだと、未ログインで叩ける `/sessions/passkey/options` で発行した challenge を、パスワードの再確認なしの登録に使い回せてしまう |
| **管理者のパスワード再設定とパスキー** | **対象ユーザーのパスキーもすべて消す** | 仕様に定めが無かったので Phase 13 で決めた。再設定は「乗っ取られたかもしれない」ときの操作でもあり、攻撃者が登録したパスキーを残すと入り続けられる。安全側に倒した。確認画面に件数を出し、完了画面で「n 件も削除しました」と伝える。本人は新しいパスワードで入って `/account` から登録し直す |
| **ユーザーの無効化とパスキー** | **消さない** | 無効化は取り消せる (Web Push の購読と同じ方針)。ログイン側が `deactivated?` を見て断るので、無効化中はパスキーでも入れない |
| **production の WebAuthn origin** | **`WEBAUTHN_ORIGIN` が未設定なら `APP_HOST` から `https://#{APP_HOST}` を導く** | 設定を 1 つ忘れただけでパスキーが動かないのを避ける。非標準ポートや別ドメインで公開するときだけ明示すればよい。`APP_HOST` も無ければ `allowed_origins` が空になり、パスキーだけが無効になってアプリは起動する (VAPID と同じ) |
| **webauthn gem の origin 設定** | **`allowed_origins` (複数形)** | 3.4.0 で入った現行 API。`origin` / `origin=` は非推奨で、呼ぶと警告を出し将来削除される (gem のソースで確認) |
| **パスキーの JS ライブラリ** | **足さない** (`app/javascript/passkey_codec.js` に自前の base64url 変換) | 新しいブラウザは `PublicKeyCredential.parseCreationOptionsFromJSON` / `parseRequestOptionsFromJSON` と `credential.toJSON()` を持つ。無いブラウザ向けの変換は 40 行ほどで済むので、webauthn-json を importmap に足す必要はない |
| **`db/seeds.rb` の冪等性** | **ENV なしでも成功する空に近い実装から始める** | CI の `db:seed:replant` を通すため。管理者作成は rake タスクに分離する |
