# 通知と PWA

[概要](00-overview.md) / [予測と要購入判定](02-forecast.md) / [画面](03-screens.md) / [デプロイ](../ops/deployment.md)

通知手段は **ダッシュボード表示 + Web Push (PWA)** のみとする。メール・チャットは使わない (送信手段を持たない)。

## 1. PWA の有効化

`rails new` が生成した PWA の雛形は、`config/routes.rb` の 2 行と `app/views/layouts/application.html.erb` の manifest link がコメントアウトされたままになっている。これを有効化する。

`app/views/pwa/manifest.json.erb`:

```json
{
  "name": "つみくら",
  "short_name": "つみくら",
  "description": "家族でつなぐ、暮らしのストック",
  "lang": "ja",
  "start_url": "/",
  "scope": "/",
  "display": "standalone",
  "theme_color": "#5B7C5A",
  "background_color": "#FAF8F3",
  "icons": [
    { "src": "/icon-192.png", "type": "image/png", "sizes": "192x192" },
    { "src": "/icon.png",     "type": "image/png", "sizes": "512x512" },
    { "src": "/icon.png",     "type": "image/png", "sizes": "512x512", "purpose": "maskable" }
  ],
  "shortcuts": [
    { "name": "買い物リスト", "url": "/shopping_list" },
    { "name": "棚卸",         "url": "/stock_takes/new" }
  ]
}
```

- `public/icon.png` (現在は 512px の Rails 既定アイコン) を「つみくら」のアイコンに差し替え、192px 版を追加する。
- `app/views/pwa/service-worker.js` には既に Web Push の雛形がコメントで入っているので、それを有効化し、購読の期限切れ対応 (`pushsubscriptionchange`) を追加する。

## 2. VAPID 鍵の管理

```bash
# 鍵の生成 (1 回だけ)
mise x -- bin/rails runner 'p WebPush.generate_key.to_h'

# Dokku に設定
dokku config:set tsumikura \
  VAPID_PUBLIC_KEY=... \
  VAPID_PRIVATE_KEY=... \
  VAPID_SUBJECT=https://tsumikura.example.com
```

- 開発環境は shell の export、または `config/credentials.yml.enc` (development キー) に置く。
- **鍵をローテーションすると既存の購読がすべて無効になる**ため、生成したら安全な場所にバックアップする。

`config/initializers/web_push.rb`:

```ruby
Rails.application.config.x.vapid = {
  public_key:  ENV["VAPID_PUBLIC_KEY"],
  private_key: ENV["VAPID_PRIVATE_KEY"],
  subject:     ENV.fetch("VAPID_SUBJECT", "mailto:admin@example.com")
}
```

## 3. 購読フロー

1. `/account` で「通知を受け取る」をオンにする → Stimulus の `push_subscription_controller.js` が動く
2. `navigator.serviceWorker.register("/service-worker")`
3. `Notification.requestPermission()`
4. `registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey })`
   - `applicationServerKey` は `<meta name="vapid-public-key">` から読む
5. `POST /web_push_subscriptions` に `endpoint` / `keys.p256dh` / `keys.auth` を送る
6. サーバは `endpoint` をキーに upsert する (`endpoint` は一意。同じブラウザで別の家族がログインして購読し直した場合は `user_id` を付け替える)

配信側 (`WebPushDeliveryJob`):

```ruby
WebPush.payload_send(
  endpoint: subscription.endpoint,
  message: payload.to_json,
  p256dh: subscription.p256dh_key,
  auth: subscription.auth_key,
  vapid: Rails.application.config.x.vapid
)
rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription
  subscription.destroy!            # 404 / 410 は購読を削除する
rescue WebPush::TooManyRequests, WebPush::PushServiceError
  # retry_on で指数バックオフ (最大 3 回)
```

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

> スケジュールは Fugit が解釈する。cron 形式の末尾にタイムゾーンを書いて、コンテナの `TZ` や Rails の `config.time_zone` の解決順に依存せず JST の 8 時に固定する (Phase 12 で実際の実行時刻を確認する)。同じ時刻を `config/tsumikura.yml` の `notifications.digest_hour` にも書いておき、画面の文言と揃える。

`DailyDigestJob` のロジック:

```
1. Item.active を一括判定する (要購入ステータスは Forecast::BatchForecaster、期限ステータスは Expiry::Evaluator)
2. item_alert_states と突き合わせ、「前回通知時よりステータスが悪化した品目」だけを抽出する
     要購入: 現在が soon / urgent で、前回の値より悪い (unknown < ok < soon < urgent)
     期限:   現在が expiring_soon / expired で、前回の値より悪い (fresh < expiring_soon < expired)
     item_alert_states の行が無い品目は、前回を unknown / fresh とみなす
3. 悪化が 0 件なら何も送らない (ジョブは黙って終了する)
4. 1 件以上なら、有効なユーザー (無効化されていない) のうち通知種別が ON の人の全購読に 1 通だけ送る
   (notify_purchases が OFF の人には要購入の悪化を、notify_expiries が OFF の人には期限の悪化を数えない。
    その人にとって 0 件なら送らない)
     title:   "つみくら"
     options: { body: "購入推奨 3件・期限間近 2件 - トイレットペーパー ほか", data: { path: "/" } }
     (生成済みの service-worker.js の雛形が { title, options } を受け取り、
      notificationclick で options.data.path を開く形なので、それに合わせる)
5. 改善した品目も含めて item_alert_states を現在値で更新する
   (= 回復後にもう一度悪化したら、また通知される)
```

うるさくならないための工夫:

| 工夫 | 内容 |
|---|---|
| ダイジェストのみ | 即時通知は一切しない。1 日 1 通 (朝 8 時) |
| 変化検知 | 前回通知時のステータスより悪化した品目がなければ送信しない |
| 静穏時間 | 日次ジョブが朝しか走らないので自動的に満たされる |
| 種別 ON/OFF | ユーザーごとに `notify_purchases` / `notify_expiries` |
| ステータス回復の記録 | 改善時も state を更新するので、同じ品目で必要なときだけ再通知される |
| `unknown` は通知しない | 判定できない品目で不安を煽らない |

## 5. iOS の制約

iOS Safari の Web Push は **「ホーム画面に追加」で PWA としてインストールした後でないと動作しない**。`/account` の通知セクションで iOS を検出したら「ホーム画面に追加してから通知をオンにしてください」と案内を出す。これはブラウザ側の仕様上の制約で、アプリ側では回避できない。
