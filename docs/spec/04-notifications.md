# 通知と PWA

[概要](00-overview.md) / [予測と要購入判定](02-forecast.md) / [画面](03-screens.md) / [デプロイ](../ops/deployment.md)

通知手段は **ダッシュボード表示 + Web Push (PWA)** のみとする。メール・チャットは使わない (送信手段を持たない)。

## 1. PWA の有効化

`rails new` が生成した PWA の雛形は、`config/routes.rb` の 2 行と `app/views/layouts/application.html.erb` の manifest link がコメントアウトされたままになっている。Phase 12 でこれを有効化した。

`app/views/pwa/manifest.json.erb`:

```json
{
  "id": "/",
  "name": "つみくら",
  "short_name": "つみくら",
  "description": "家族でつなぐ、暮らしのストック",
  "lang": "ja",
  "dir": "ltr",
  "start_url": "/",
  "scope": "/",
  "display": "standalone",
  "orientation": "portrait",
  "theme_color": "#5B7C5A",
  "background_color": "#FAF8F3",
  "icons": [
    { "src": "/icon.svg", "type": "image/svg+xml", "sizes": "any" },
    { "src": "/icon.png", "type": "image/png", "sizes": "512x512" }
  ],
  "shortcuts": [
    { "name": "買い物リスト", "short_name": "買い物", "url": "/shopping_list" },
    { "name": "棚卸",         "short_name": "棚卸",   "url": "/stock_takes/new" }
  ]
}
```

- manifest が参照するファイルは実在すること (`spec/requests/pwa_spec.rb` で固定している)。
- `public/icon.svg` は「つ」の字だけの暫定アイコン、`public/icon.png` は Rails 既定の 512px のまま。
  **デザインしたアイコン (512px / 192px の PNG) への差し替えが残っている**
  ([未決事項](../plan/open-questions.md))。192px を足すときは `icons` にも 1 行足す。
- **`purpose: "maskable"` の行は今は置かない。** Rails 既定のアイコンには安全域 (周囲 20%) が無く、
  maskable と宣言すると Android で端が切れる。安全域を持つアイコンに差し替えたときに足す。
- `id` は `"/"` に固定する (`start_url` が変わっても同じアプリとして扱われる)。
- レイアウトには `theme-color` の meta を置く (manifest の `theme_color` と同じ値)。
  `viewport-fit=cover` は Phase 4 で導入済み。
- `manifest` / `service-worker` は `Rails::PwaController` が返す。これは `ApplicationController` を
  継承しないので**認証を通らない = 未ログインでも取得できる**。「ホーム画面に追加」はログイン前にも
  行われるので、これは仕様どおり (`spec/requests/pwa_spec.rb` で固定)。

### service worker で決めたこと

`app/views/pwa/service-worker.js` は `push` / `notificationclick` を扱う。

- **キャッシュ (オフライン対応) は入れない。** 在庫の記録はフォームの POST が中心で、古い在庫数の
  画面をキャッシュから見せると「買ったはずなのに 0 のまま」のような害が大きい。`fetch` ハンドラを
  登録しないので、通信はすべてふだんどおりネットワークに行く。
  店頭の圏外でチェックをキューイングする案は今回も対応しない (Phase 11 からの申し送りのまま)。
- `push` は `{ title, options }` を受け取って `showNotification(title, options)` を呼ぶ。
  **JSON が読めなくても必ず通知を出す** (`try` で既定の本文に落とす)。`userVisibleOnly` の購読で
  通知を出さない push が続くと、ブラウザ (特に Safari) が購読そのものを取り消すため。
  `options` には `icon: "/icon.png"` と `tag` を付ける (ダイジェストは `daily-digest`、
  テスト送信は `notification-test`。同じ tag の通知は置き換わるので通知欄に積み上がらない)。
- `notificationclick` は `options.data.path` を開く。**同じパスのタブが既に開いていれば `focus`**、
  無ければ `openWindow`。
  **開いているタブを `navigate()` で使い回すことはしない**: `includeUncontrolled: true` で拾った
  制御下に無いタブでは `TypeError` になって `waitUntil` ごと失敗し (タップしても何も起きない)、
  成功したとしても入力途中の画面を書き換えてしまう。
  `path` は `new URL(path, self.location.origin)` に通し、**同一オリジンでなければ `/` を開く**。
- `install` で `skipWaiting()`、`activate` で `clients.claim()` する
  (`fetch` を持たないので、更新を待たせる理由がない)。
- **`pushsubscriptionchange` は扱わない。** 新しい購読をサーバへ送るにはログイン中の Cookie が要り、
  Service Worker から確実に届けられないため。代わりに **`push_subscription_controller.js` が接続の
  たびに現在の購読を送り直す**方式にした (サーバ側は `endpoint` をキーにした upsert なので、
  何度送っても行は増えない)。つまり**次にアカウント設定を開いた時点で復旧する**。

## 2. VAPID 鍵の管理

鍵は**手元で生成**して環境変数で渡す (サーバに生成させると、控えを取り損ねたときに復旧できない)。

```bash
# 鍵の生成 (1 回だけ)。手元のリポジトリで実行する
mise x -- ruby -rweb_push -e 'p WebPush.generate_key.to_h'
```

Dokku への設定は [初回デプロイ手順書 3 節](../ops/first-deploy.md#3-環境変数) のとおり `read -rs` で渡す
(シェル履歴と `ps` に秘密鍵を残さない)。

- 開発環境は shell の export で渡す。**未設定でもアプリは起動する** (通知だけが無効になり、
  `/account` の通知セクションが「サーバに通知の鍵が設定されていません」になる)。
- **鍵をローテーションすると既存の購読がすべて無効になる**ため、生成したら安全な場所にバックアップする
  (ローテーション後は各端末で登録し直しが要る。配信は 401 になり、購読は消さずにログだけ残る)。

`config/initializers/web_push.rb`:

```ruby
Rails.application.config.x.vapid = {
  public_key:  ENV["VAPID_PUBLIC_KEY"].presence,
  private_key: ENV["VAPID_PRIVATE_KEY"].presence,
  subject:     ENV["VAPID_SUBJECT"].presence || "mailto:admin@example.com"
}
```

読み出しは `Vapid` モジュール (`app/models/vapid.rb`) を通す (`Vapid.keys` / `Vapid.public_key` /
`Vapid.configured?`)。**秘密鍵を例外メッセージやログに出さない**ため、ここ以外から `config.x.vapid` を
読まない。

公開鍵は**全ページの `<meta>` には置かない**。使うのはアカウント設定の通知セクションだけなので、
そこの `data-push-subscription-public-key-value` に持たせる。

## 3. 購読フロー

1. `/account` の通知セクションで「この端末で通知を受け取る」を押す → Stimulus の
   `push_subscription_controller.js` が動く
2. `navigator.serviceWorker.register("/service-worker", { scope: "/" })`
3. `Notification.requestPermission()`
4. `navigator.serviceWorker.ready` を待ってから
   `registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey })`
   - **`ready` を待つ**。初回は Service Worker が installing のままで、active になる前に
     `subscribe` を呼ぶと `InvalidStateError: no active Service Worker` になる
   - `applicationServerKey` は `data-push-subscription-public-key-value` の base64url を
     `Uint8Array` に直して渡す (鍵が未設定の環境ではセクション自体を出さない)
5. `POST /web_push_subscriptions` に `endpoint` / `p256dh` / `auth` を JSON で送る (CSRF トークンを付ける)
6. サーバは `endpoint` をキーに upsert する (`WebPushSubscription.upsert_for`)。`endpoint` は
   **端末 + ブラウザに 1 つ**なので一意。同じブラウザで別の家族がログインして購読し直した場合は
   `user_id` を付け替える (行は増やさない)。一意制約の競合 (`RecordNotUnique`) は掴み直して付け替える
7. 応答の `id` を JS が覚えて「この端末の通知をオフにする」(`DELETE /web_push_subscriptions/:id`) で使う

画面に出す状態は 4 つ: 未対応ブラウザ / 許可が拒否済み / iOS でホーム画面に未追加 / 購読中。
**iOS の判定を「未対応」より先に出す** (iOS Safari はホーム画面に追加するまで `PushManager` を
持たないので、先に「未対応」と書くと打つ手が無いように見える)。

JS 側で決めたこと:

- **通信に失敗したら必ずボタンを出し直す** (`send` は `try`、`unsubscribe` は `finally`)。
  どちらのボタンも出ないまま詰まる / 端末では解除済みなのに「オフにする」のまま、を防ぐ。
- **セッション切れを成功と誤認しない**: `fetch` は 302 に追従してログイン画面の 200 を返すので、
  `response.redirected` と `content-type` を確認してから `response.json()` する。
- **VAPID 鍵をローテーションしたあとの購読は自動で取り直す**: `subscription.options.applicationServerKey`
  を今の公開鍵と比べ、違えば `unsubscribe()` してから購読し直す (許可済みならユーザー操作は要らない)。
  これをしないと、その端末は配信が 401 になり続けるのに画面は「受け取ります」のままになる。
- 購読 / 解除に成功したときだけ `Turbo.visit(location.href, { action: "replace" })` で
  下の「通知を受け取る端末」の一覧を描き直す。**接続時の再同期 (`refresh`) からは呼ばない**
  (connect → send → visit → connect の無限ループになる)。

受け付ける値の制約 (`WebPushSubscription`):

| 列 | 制約 |
|---|---|
| `endpoint` | 必須・一意・ASCII のみ・`https://` で始まる・**ホストが許可リストにあり 443 番**・2048 文字まで。DB にも `LIKE 'https://%'` の check 制約を置く |
| `p256dh_key` | 必須・base64url の文字種のみ・255 文字まで・**デコードして 65 バイトで先頭が `0x04`** (非圧縮の楕円曲線の点) |
| `auth_key` | 必須・base64url の文字種のみ・255 文字まで・**デコードして 16 バイト** |
| `user_agent` | 255 文字に切り詰めて通す (長いだけで購読を拒まない) |

**Push サービスのホストの許可リスト** (`WebPushSubscription::ALLOWED_HOSTS`):

| ブラウザ | ホスト |
|---|---|
| Chrome / Android | `fcm.googleapis.com`、`android.googleapis.com` |
| Firefox | `*.push.services.mozilla.com` |
| Edge | `*.notify.windows.com` |
| Safari / iOS | `web.push.apple.com`、`*.push.apple.com` |

**新しいブラウザ / Push サービスに対応するときは、ここに足す。**
許可リストにするのは、ログイン済みの家族なら誰でも endpoint を登録でき、テスト送信で
サーバから任意の `https://` URL へ POST させられるため (blind SSRF と増幅)。
併せて **`URI.parse` できない値を弾く** (配信時の `URI::InvalidURIError` のメッセージには
endpoint 全文が入るのでログに残ってしまう) し、**非 ASCII も弾く**
(2048 文字の非 ASCII は btree の index の上限を超えて 500 になる)。

- 鍵の長さをここで検証しておくと、配信時に OpenSSL の例外で毎朝失敗し続けるのを防げる。
- `user_id` / `failure_count` / `last_delivered_at` はフォームから変更できない (permit しない)。
- 他人の購読は削除できない (`Current.user.web_push_subscriptions` から引く)。既に消えている購読への
  操作は **404 にせず成功として扱う** (古い画面からの操作でエラー画面を見せない)。
- **登録には `rate_limit to: 20, within: 1.minute`**、テスト送信には `to: 5, within: 1.minute`。
- **1 ユーザーの購読は 20 件まで** (`MAX_PER_USER`)。超えたら**古い方から消す**。
  422 で断ると、実在する端末が購読し直せなくなる方が困るため
  (endpoint での upsert なので、ふつうに使っているぶんには増えない)。
- `endpoint` / `p256dh` / `auth` は `config/initializers/filter_parameter_logging.rb` でログから落とす。
  画面にも `endpoint` は出さない (端末を特定できる値のため、一覧には `user_agent` の要約だけを出す)。

配信側 (`WebPushDeliveryJob`) は **1 購読 1 ジョブ**にする (1 ジョブで全購読を回すと、1 台が遅い
だけで残りの家族に届かなくなる)。

```ruby
WebPush.payload_send(
  endpoint: subscription.endpoint,
  p256dh:   subscription.p256dh_key,
  auth:     subscription.auth_key,
  message:  payload.to_json,
  vapid:    Vapid.keys,
  ttl:      12.hours.to_i,   # 1 日 1 通なので翌朝まで残さない
  urgency:  "normal",
  open_timeout: 5, ssl_timeout: 5, read_timeout: 10
)
```

**タイムアウトは必ず指定する。** Net::HTTP の既定は open 60 秒 + read 60 秒で、家庭用の小さな
ワーカー (3 スレッド) がこれで塞がれると他の通知まで止まる。

| Push サービスの応答 | gem の例外 | ふるまい |
|---|---|---|
| 404 / 410 | `InvalidSubscription` / `ExpiredSubscription` | 購読を**削除**する (残しても二度と届かない) |
| 401 / 403 | `Unauthorized` | 購読は**消さない** (鍵を戻せば復活する)。失敗回数を増やしてログだけ残す |
| 413 | `PayloadTooLarge` | 購読は消さず記録だけ残す |
| 429 / 5xx | `TooManyRequests` / `PushServiceError` | `retry_on` で指数バックオフ (最大 3 回) |
| 届く前に落ちる (タイムアウト / DNS / 接続断 / TLS) | `Net::OpenTimeout`、`Net::ReadTimeout`、`SocketError`、`Errno::ECONNRESET`、`Errno::ECONNREFUSED`、`Errno::EHOSTUNREACH`、`OpenSSL::SSL::SSLError` | 同じく `retry_on` (`NETWORK_ERRORS`) |
| 本文を暗号化できない | `OpenSSL::PKey::PKeyError` / `ArgumentError` | 鍵が壊れていて直しようがないので購読を**削除**する |
| そのほか | `ResponseError` | 記録だけ残す (再送しても直らないことが多い) |

- **ネットワークの失敗を必ず再送に載せる。** state は送信の成否によらず更新されるので、
  朝 8 時に DNS が一瞬途切れただけで諦めると、**その日の悪化は二度と通知されない**。
- **再送を諦めたときは例外を上げず、警告ログだけ残す** (`retry_on` にブロックを渡す)。
  上げると `solid_queue_failed_executions` に残り続けて毎朝たまっていく。1 日 1 通なので、
  翌朝またやり直せば足りる。
- 成功したら `last_delivered_at` を更新し `failure_count` を 0 に戻す。失敗したら `failure_count` を増やす。
- **ログには購読の id と Push サービスのホストだけを出す** (`endpoint` も VAPID の鍵も出さない)。
- 鍵が未設定の環境ではジョブは何もせずに終わる (毎朝失敗し続けない)。

## 4. 日次ダイジェスト

`config/recurring.yml`:

```yaml
production:
  clear_solid_queue_finished_jobs:
    command: "SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)"
    schedule: every hour at minute 12
  daily_digest:
    class: DailyDigestJob
    queue: default
    schedule: "0 8 * * * Asia/Tokyo"
```

> スケジュールは Fugit が解釈する。cron 形式の末尾にタイムゾーンを書いて、コンテナの `TZ` や Rails の
> `config.time_zone` の解決順に依存せず JST の 8 時に固定する (`Fugit.parse_cron("0 8 * * * Asia/Tokyo")`
> が `zone: "Asia/Tokyo"` を持つことは確認済み)。**development / test には書かない** (家の PC を開いた朝に
> 通知が飛ばないように)。手で試すときは `bin/rails runner 'DailyDigestJob.perform_now'`。
> 同じ時刻を `config/tsumikura.yml` の `notifications.digest_hour` にも書いてあり、画面の文言はそちらを読む。

`DailyDigestJob` のロジック:

```
0. today = Date.current を 1 度だけ取る (日付をまたぐ瞬間に走っても基準日がずれないように)
   買い物リストの古い永続行を掃除する (ShoppingListItem.purge_stale!(today))
1. Item.active を一括判定する (Forecast::BatchForecaster と Expiry::Evaluator に today を渡す)
2. item_alert_states と突き合わせ、「前回突き合わせたときよりステータスが悪化した品目」だけを抽出する
     要購入: 現在が soon / urgent で、前回の値より悪い (unknown < ok < soon < urgent)
     期限:   現在が expiring_soon / expired で、前回の値より悪い (fresh < expiring_soon < expired)
     item_alert_states の行が無い品目は、前回を unknown / fresh とみなす
3. 悪化が 0 件なら何も送らない (ジョブは黙って終了する)
4. 1 件以上なら、有効なユーザー (無効化されていない) のうち通知種別が ON の人の**全購読に 1 通ずつ**送る
   (notify_purchases が OFF の人には要購入の悪化を、notify_expiries が OFF の人には期限の悪化を数えない。
    その人にとって 0 件なら送らない)
     title:   "つみくら"
     options: { body: "購入推奨 1 件・そろそろ購入 2 件・期限切れ 1 件・期限間近 1 件 — トイレットペーパー ほか",
                icon: "/icon.png", tag: "daily-digest", data: { path: "/" } }
5. 送信の成否にかかわらず、**全品目**の item_alert_states を更新する
   (改善も記録するので、回復後にもう一度悪化したらまた通知される)
   ただし**見送り中の品目の要購入ステータスは前回値のまま据え置く**
   アーカイブ済みの品目の行は消す
```

**本文はステータスごとの内訳にする。** `soon` をまとめて「購入推奨」と言うと、そこまで急いでいない
品目まで買いに行かせてしまう。0 件の内訳は並べない。並びは悪い方から
(`購入推奨 → そろそろ購入 → 期限切れ → 期限間近`)。

手で流したぶんと定時実行が重なっても 2 通にならないよう、ジョブに
`limits_concurrency key: "daily_digest"` を付ける。

判定そのもの (前回値と現在値から通知対象と本文を決める部分) は `Notifications::Digest` という
**DB にも Rails にも依存しない PORO** に切り出してある (`spec_helper` だけで回せる)。

- 比較に使うのは `status` だけ (`days_left` は毎日 1 ずつ動くので、差分で通知すると毎朝鳴る)。
- 悪化の向きは `Forecast::Calculator::RANK` と `Expiry::Status::RANK` から取る (順位を 2 か所に書かない)。
- `status` は Symbol なので、`item_alert_states` には**文字列で保存して文字列で比べる**。
- 本文の語彙は画面と同じものを使う (`ja.forecast.status.urgent` = 購入推奨 /
  `ja.expiry.status.expiring_soon` = 期限間近)。PORO は Rails に依存しないので、ラベルは呼び出し側が渡す。
- 知らない `status` が入っていても例外にしない (1 品目の値がおかしいだけで毎朝のダイジェストが
  丸ごと止まらないように、「通知しない」に倒す)。

決めたこと:

| 論点 | 決定 | 理由 |
|---|---|---|
| **見送り中 (スヌーズ) の品目** | **要購入の通知からは除く。期限の通知からは除かない** | 「今回は買わない」と決めた品目で毎朝鳴るのがいちばんうるさい。見送りは買い物の話なので、期限切れは別途知らせる。境界は買い物リストと同じ `snoozed_until >= today` |
| **見送り中の品目の state** | **要購入ステータスは前回値のまま据え置く** (期限は現在値で更新する) | 現在値で記録すると、見送り中に `ok → urgent` と悪化した品目が、見送りが切れたあとも「横ばい」になって**二度と通知されない**。据え置けば、見送りが切れた翌朝にちゃんと鳴る |
| **初回実行** | 既存の悪い品目が全部「悪化」として **1 通にまとまる**のを許容する | 1 通で収まるうえ、初回の 1 回だけ。抑える仕組みを足すほうが複雑 |
| **冪等性** | 同じ日に 2 回走っても 2 通目は送られない | 1 回目で state が現在値になるため (悪化 0 件になる) |
| 鍵が未設定の日 | 送らないが state は更新する | 送信の成否で state の更新を分岐させない (追いにくくなる) |
| 買い物リストの掃除 | **DailyDigestJob の中で呼ぶ** (ジョブを分けない) | 「1 日 1 回でよい掃除」で、失敗しても翌朝やり直せる。ジョブを増やすと `recurring.yml` の行も監視対象も増える。**通知の判定とは独立**している (見送り中かどうかは `snoozed_until >= today` の where だけで決まるので、掃除の順序は通知に影響しない) |

うるさくならないための工夫:

| 工夫 | 内容 |
|---|---|
| ダイジェストのみ | 即時通知は一切しない。1 日 1 通 (朝 8 時) |
| 変化検知 | 前回突き合わせたときのステータスより悪化した品目がなければ送信しない |
| 静穏時間 | 日次ジョブが朝しか走らないので自動的に満たされる |
| 種別 ON/OFF | ユーザーごとに `notify_purchases` / `notify_expiries` (JS 無しで動くフォーム) |
| ステータス回復の記録 | 改善時も state を更新するので、同じ品目で必要なときだけ再通知される |
| `unknown` は通知しない | 判定できない品目で不安を煽らない |
| 見送り中は通知しない | 「今回は買わない」と決めた品目で毎朝鳴らさない |

## 5. 割り切っていること

| こと | いまの挙動 | 理由と将来の選択肢 |
|---|---|---|
| **ログアウトしても購読は残る** | その端末には通知が届き続ける | 通知の中身は**世帯で共通**で、ユーザーごとに変わるのは種別の ON/OFF だけなので、実害は小さい。止めたいときは `/account` の「通知を受け取る端末」から削除する。ログアウト時に自動で消す案は[未決事項](../plan/open-questions.md)に置いた |
| **同じ端末で別の家族が `/account` を開くと購読がその人に移る** | `endpoint` は端末に 1 つなので `user_id` が付け替わる | 「1 台の端末に 1 人」という前提。付け替えないと同じ端末に 2 通届く。移った結果、種別の ON/OFF はその人の設定になる |
| **購読の再同期が `/account` でしか働かない** | Push サービス側で購読が作り直されると、次に `/account` を開くまで通知が止まる | `pushsubscriptionchange` を Service Worker で処理できない (ログイン中の Cookie が要る) ため。レイアウトに常駐させて全ページで再同期する案は[未決事項](../plan/open-questions.md)に置いた。1 日 1 通の通知なので、届かない日が続いたら `/account` を開いてもらう |
| **オフラインでは何もできない** | キャッシュを持たないので、圏外では画面が開かない | 古い在庫数を見せる害の方が大きいと判断した (1 節)。店頭でのチェックのキューイングも入れていない |

## 6. iOS の制約

iOS Safari の Web Push は **「ホーム画面に追加」で PWA としてインストールした後でないと動作しない**。
`/account` の通知セクションで iOS を検出したら「ホーム画面に追加してから通知をオンにしてください」と
案内を出す。これはブラウザ側の仕様上の制約で、アプリ側では回避できない。

判定は `navigator.userAgent` の `iPad|iPhone|iPod` に加えて、**iPadOS 13 以降が Macintosh を名乗る**ため
`Macintosh` かつ `navigator.maxTouchPoints > 1` も iOS とみなす。インストール済みかどうかは
`window.navigator.standalone` と `matchMedia("(display-mode: standalone)")` の両方で見る。

## 7. 実機でしか確かめられないこと

Push の許可ダイアログと Service Worker はヘッドレスブラウザで扱いにくいので、`js: true` の system spec は
書いていない。代わりに **Stimulus のターゲットとデータ属性がビューに出ていること**を request spec
(`spec/requests/account_notifications_spec.rb`) で固定してある。実機では次の順で確かめる。

1. `dokku config:set` で VAPID の 3 変数を設定し、デプロイする
2. スマホのブラウザで開いてログイン → **共有メニューから「ホーム画面に追加」**
3. ホーム画面のアイコンから開き、`/account` の通知セクションで「この端末で通知を受け取る」を押す
   → 許可ダイアログで「許可」 → 文言が「この端末で通知を受け取ります。」に変わる
4. 「登録済みの端末」にその端末が出ること (`iPhone / Safari` などの要約)
5. **テスト送信**を押す → 数秒で通知が届き、タップすると `/account` が開くこと
6. 通知をタップしたとき、既にアプリのタブが開いていればそれが前面に来ること
7. `/account` で「この端末の通知をオフにする」→ 一覧から消え、テスト送信が届かなくなること
8. 翌朝 8 時 (JST) に日次ダイジェストが届くこと。届かないときは
   `dokku logs tsumikura -n 200` と `SolidQueue::RecurringExecution` を確認する
9. 通知の種別を片方 OFF にして、その種別の悪化だけでは届かないこと
