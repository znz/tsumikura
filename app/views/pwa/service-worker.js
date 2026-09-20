// つみくらの Service Worker (docs/spec/04-notifications.md 1 節)。
//
// **キャッシュ (オフライン対応) は入れない。** 在庫の記録はフォームの POST が中心で、
// 古い在庫数の画面をキャッシュから見せると「買ったはずなのに 0 のまま」のような害が出る。
// fetch ハンドラを登録しないので、通信はすべてふだんどおりネットワークに行く。
//
// pushsubscriptionchange (Push サービス側で購読が作り直されたとき) はここでは扱わない。
// 新しい購読をサーバに送るにはログイン中の Cookie が要り、Service Worker から確実に
// 届けられないため。**次にアカウント設定を開いたときに購読し直す**方式にしている
// (push_subscription_controller.js が接続時に現在の購読を必ず送り直す)。

// 通知の内容が変わる更新をすぐ反映させる (fetch を持たないので待たせる理由がない)
self.addEventListener("install", () => {
  self.skipWaiting()
})

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim())
})

// 配信は DailyDigestJob / NotificationTestsController が { title, options } を送る。
// **必ず通知を出す**: userVisibleOnly の購読で通知を出さない push が続くと、
// ブラウザ (特に Safari) が購読を取り消してしまう
self.addEventListener("push", (event) => {
  let payload = {}

  try {
    payload = (event.data && event.data.json()) || {}
  } catch (error) {
    payload = {}
  }

  const title = payload.title || "つみくら"
  const options = payload.options || { body: "つみくらからのお知らせがあります。" }

  event.waitUntil(self.registration.showNotification(title, options))
})

// タップしたら options.data.path を開く。既に同じ画面を開いているタブがあればそれを使う
self.addEventListener("notificationclick", (event) => {
  event.notification.close()

  const data = event.notification.data || {}
  const target = resolvePath(data.path)

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clientList) => {
      for (const client of clientList) {
        if (samePath(client.url, target) && "focus" in client) {
          return client.focus()
        }
      }

      // 開いているタブを navigate で使い回すことはしない。制御下に無いタブでは例外になり、
      // 成功しても入力途中の画面を書き換えてしまう
      return self.clients.openWindow(target)
    })
  )
})

// payload は自分のサーバが作るが、万一よそのオリジンが入っていたら開かない
function resolvePath(path) {
  try {
    const url = new URL(path || "/", self.location.origin)

    return url.origin === self.location.origin ? url.pathname + url.search : "/"
  } catch (error) {
    return "/"
  }
}

function samePath(clientUrl, target) {
  try {
    return new URL(clientUrl).pathname === new URL(target, self.location.origin).pathname
  } catch (error) {
    return false
  }
}
