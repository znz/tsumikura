import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// この端末の Web Push の購読 (docs/spec/04-notifications.md 3 節)。
//
// JS が無い / 未対応のブラウザでは、通知の種別 ON/OFF のフォームだけが残る
// (購読のボタンはサーバ側で hidden にしてあり、この controller が出す)。
//
// 接続のたびに「今ブラウザが持っている購読」をサーバへ送り直す。サーバ側は endpoint を
// キーにした upsert なので何度送っても行は増えず、Push サービス側で購読が作り直されても
// (pushsubscriptionchange) 次にこの画面を開いた時点で復旧する。
export default class extends Controller {
  static targets = ["status", "subscribe", "unsubscribe", "unsupported", "ios"]
  static values = { url: String, publicKey: String }

  connect() {
    // サーバ側の購読の id。「通知をオフ」で使う (画面には endpoint を出さない)
    this.subscriptionId = null
    this.refresh()
  }

  // ---- 状態の表示 ----

  async refresh() {
    this.hideAll()

    // iOS はホーム画面に追加するまで PushManager を持たない。
    // 先に「未対応」と出すと打つ手が無いように見えるので、案内を優先する
    if (this.needsHomeScreen) {
      this.iosTarget.hidden = false
      this.setStatus("")
      return
    }

    if (!this.supported) {
      this.unsupportedTarget.hidden = false
      this.setStatus("")
      return
    }

    if (Notification.permission === "denied") {
      this.setStatus("このブラウザで通知が拒否されています。ブラウザの設定で許可してからやり直してください。")
      return
    }

    let subscription = null
    try {
      subscription = await this.currentSubscription()

      // VAPID 鍵をローテーションしたあとの購読は、配信が 401 になり続けて自力では直らない。
      // 許可済みなら、ユーザー操作なしで取り直す
      if (subscription && !this.matchesPublicKey(subscription)) {
        await subscription.unsubscribe()
        subscription = Notification.permission === "granted" ? await this.createSubscription() : null
      }
    } catch (error) {
      this.setStatus("通知の状態を確認できませんでした。")
      return
    }

    if (subscription) {
      // ここからは画面を描き直さない (connect → send → visit → connect の無限ループになる)
      await this.send(subscription, { reload: false })
    } else {
      this.showSubscribe()
    }
  }

  // ---- 操作 ----

  async subscribe(event) {
    event.preventDefault()
    this.setStatus("通知の許可を確認しています…")

    let permission = "default"
    try {
      permission = await Notification.requestPermission()
    } catch (error) {
      this.showSubscribe()
      this.setStatus("通知の許可を確認できませんでした。")
      return
    }

    if (permission !== "granted") {
      this.showSubscribe()
      this.setStatus("通知が許可されませんでした。")
      return
    }

    try {
      await this.send(await this.createSubscription(), { reload: true })
    } catch (error) {
      this.showSubscribe()
      this.setStatus("通知を登録できませんでした。")
    }
  }

  async unsubscribe(event) {
    event.preventDefault()
    this.setStatus("解除しています…")

    let removed = false
    try {
      const subscription = await this.currentSubscription()
      if (subscription) await subscription.unsubscribe()

      if (this.subscriptionId) {
        const response = await fetch(`${this.urlValue}/${this.subscriptionId}`, {
          method: "DELETE",
          headers: this.headers,
          credentials: "same-origin"
        })
        removed = response.ok && !response.redirected
      } else {
        removed = true
      }
    } catch (error) {
      // 端末側で解除できていれば通知は止まる。サーバ側の行は次に開いたときに整理される
    } finally {
      // 端末では解除済みなのに画面が「オフにする」のままにならないよう、必ず戻す
      this.subscriptionId = null
      this.showSubscribe()
    }

    if (removed) {
      this.reload()
    } else {
      this.setStatus("この端末では通知を受け取りません (一覧の反映は次に開いたときになります)。")
    }
  }

  // ---- サーバとのやりとり ----

  async send(subscription, { reload = false } = {}) {
    const json = subscription.toJSON()
    let response = null

    try {
      response = await fetch(this.urlValue, {
        method: "POST",
        headers: this.headers,
        credentials: "same-origin",
        body: JSON.stringify({
          web_push_subscription: {
            endpoint: json.endpoint,
            p256dh: json.keys.p256dh,
            auth: json.keys.auth
          }
        })
      })
    } catch (error) {
      this.showSubscribe()
      this.setStatus("通信できませんでした。電波の届くところでもう一度お試しください。")
      return false
    }

    // セッションが切れると fetch がログイン画面へのリダイレクトに追従し、
    // 200 の HTML が返る (response.ok は true のまま)
    if (response.redirected || !this.isJson(response)) {
      this.showSubscribe()
      this.setStatus("ログインし直してから、もう一度お試しください。")
      return false
    }

    if (!response.ok) {
      this.showSubscribe()
      this.setStatus("通知の登録をサーバに保存できませんでした。")
      return false
    }

    const body = await response.json().catch(() => ({}))
    this.subscriptionId = body.id
    this.showSubscribed()
    if (reload) this.reload()

    return true
  }

  async registration() {
    await navigator.serviceWorker.register("/service-worker", { scope: "/" })

    // 初回は installing のままなので、active になるまで待たないと
    // pushManager.subscribe が InvalidStateError になる
    return navigator.serviceWorker.ready
  }

  async currentSubscription() {
    const registration = await this.registration()

    return await registration.pushManager.getSubscription()
  }

  async createSubscription() {
    const registration = await this.registration()

    return await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(this.publicKeyValue)
    })
  }

  // 下の「通知を受け取る端末」の一覧を描き直す。**refresh() からは呼ばない**
  reload() {
    Turbo.visit(window.location.href, { action: "replace" })
  }

  // ---- 表示の切り替え ----

  showSubscribe() {
    this.subscribeTarget.hidden = false
    this.unsubscribeTarget.hidden = true
    this.setStatus("この端末では通知を受け取りません。")
  }

  showSubscribed() {
    this.subscribeTarget.hidden = true
    this.unsubscribeTarget.hidden = false
    this.setStatus("この端末で通知を受け取ります。")
  }

  hideAll() {
    this.subscribeTarget.hidden = true
    this.unsubscribeTarget.hidden = true
    this.unsupportedTarget.hidden = true
    this.iosTarget.hidden = true
  }

  setStatus(text) {
    this.statusTarget.textContent = text
  }

  // ---- 環境の判定 ----

  get headers() {
    const token = document.querySelector("meta[name='csrf-token']")

    return {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "X-CSRF-Token": token ? token.content : ""
    }
  }

  isJson(response) {
    return (response.headers.get("content-type") || "").includes("application/json")
  }

  // 購読が今の VAPID 公開鍵で作られたものか
  matchesPublicKey(subscription) {
    const applied = subscription.options && subscription.options.applicationServerKey
    // 比べられないブラウザでは作り直さない (取り直しで通知が止まる方が困る)
    if (!applied) return true

    const actual = new Uint8Array(applied)
    const expected = urlBase64ToUint8Array(this.publicKeyValue)
    if (actual.length !== expected.length) return false

    for (let i = 0; i < actual.length; i++) {
      if (actual[i] !== expected[i]) return false
    }

    return true
  }

  get supported() {
    return "serviceWorker" in navigator && "PushManager" in window && "Notification" in window
  }

  // iPadOS 13 以降は UA が Macintosh になるので、タッチの有無も見る
  get isIOS() {
    const ua = navigator.userAgent

    return /iPad|iPhone|iPod/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)
  }

  get isStandalone() {
    return window.navigator.standalone === true ||
      window.matchMedia("(display-mode: standalone)").matches
  }

  get needsHomeScreen() {
    return this.isIOS && !this.isStandalone
  }
}

// VAPID の公開鍵 (base64url) を pushManager.subscribe が受け取る Uint8Array に直す
function urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4)
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/")
  const raw = window.atob(base64)
  const output = new Uint8Array(raw.length)

  for (let i = 0; i < raw.length; i++) {
    output[i] = raw.charCodeAt(i)
  }

  return output
}
