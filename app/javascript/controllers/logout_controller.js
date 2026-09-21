import { Controller } from "@hotwired/stimulus"

// ログアウトするとき、この端末の Web Push の購読も解除する
// (docs/spec/04-notifications.md 5 節)。
//
// **何があってもログアウトは進める。** 未対応のブラウザ、Service Worker が未登録、
// 例外、応答が返ってこない、のいずれでも、遅くとも TIMEOUT_MS 後にはフォームを送る。
// 機能検出 → try / catch の形は push_subscription_controller.js に揃えてある。
//
// JS が無い環境ではふつうのフォームとして送られ、購読はこれまでどおり残る
// (サーバ側は push_endpoint が無ければ何もしない)。

// 端末側の解除を待つ上限。押してからログアウトするまで待たせない
const TIMEOUT_MS = 2000

export default class extends Controller {
  static targets = ["endpoint"]

  connect() {
    // 解除の処理が走っている最中か (二重 submit の防止)
    this.pending = false
    // 自分でフォームを投げ直す段階に入ったか
    this.ready = false
  }

  async submit(event) {
    // 自分で投げ直した submit。ここで止めるとログアウトできなくなるので素通しする
    if (this.ready) return

    // ここで止めておかないと、endpoint を入れる前にフォームが飛ぶ
    event.preventDefault()

    // 解除を待っている間の連打は無視する (1 回目の処理がフォームを送る)
    if (this.pending) return
    this.pending = true

    try {
      await this.withTimeout(this.unsubscribe())
    } catch (error) {
      // 解除できなくてもログアウトは進める (購読は /account の一覧からも消せる)
    } finally {
      this.ready = true
      this.send()
    }
  }

  // この端末の購読を解除し、endpoint を hidden に入れる (サーバ側で行を消すため)。
  // ここで投げた例外は submit() 側で握りつぶされる
  async unsubscribe() {
    if (!("serviceWorker" in navigator)) return

    // register はしない。登録済みでなければ購読も無い
    const registration = await navigator.serviceWorker.getRegistration()
    if (!registration || !registration.pushManager) return

    const subscription = await registration.pushManager.getSubscription()
    if (!subscription) return

    // 先に endpoint を控える (unsubscribe したあとは読めなくなる実装がある)
    if (this.hasEndpointTarget) this.endpointTarget.value = subscription.endpoint

    await subscription.unsubscribe()
  }

  // 応答が返らない環境でボタンが効かなくならないよう、待つ時間に上限を置く。
  // 時間切れのときは endpoint が入らないまま送る (購読は残るがログアウトはできる)
  withTimeout(promise) {
    return Promise.race([
      promise,
      new Promise((resolve) => setTimeout(resolve, TIMEOUT_MS))
    ])
  }

  send() {
    try {
      // requestSubmit なら submit イベントが出るので Turbo に載る
      this.element.requestSubmit()
    } catch (error) {
      // requestSubmit を持たない古いブラウザ。Turbo には載らないが確実に送れる
      this.element.submit()
    }
  }
}
