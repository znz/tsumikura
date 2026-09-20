import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"
import { parseCreationOptions, creationCredentialToJSON } from "passkey_codec"

// パスキーの登録 (docs/spec/05-auth.md 5 節)。アカウント設定の「パスキー」セクションで動く。
//
// Phase 12 の push_subscription_controller.js と同じ型:
// (1) 機能検出 -> (2) 表示の切り替え (未対応 / 登録フォーム) -> (3) エラー処理。
// fetch は**セッション切れのリダイレクト追従**を必ず見る
// (302 に追従したログイン画面の 200 を成功と誤認しない)。
//
// 登録済みの一覧と削除ボタンはサーバ側で描くので、JS が無くても一覧と削除はできる。
// 登録だけが JS を要る (navigator.credentials.create がブラウザの API なので)。
export default class extends Controller {
  static targets = ["form", "status", "submit", "unsupported", "password", "nickname"]
  static values = { url: String, optionsUrl: String }

  connect() {
    this.busy = false

    if (this.supported) {
      this.formTarget.hidden = false
      this.unsupportedTarget.hidden = true
    } else {
      this.formTarget.hidden = true
      this.unsupportedTarget.hidden = false
    }
  }

  // ---- 操作 ----

  async register(event) {
    event.preventDefault()
    if (this.busy) return

    const password = this.passwordTarget.value
    if (!password) {
      this.setStatus("現在のパスワードを入力してください。")
      return
    }

    this.setBusy(true)
    this.setStatus("パスキーを作成しています…")

    try {
      await this.createPasskey(password)
    } finally {
      // 入力欄にパスワードを残さない
      this.passwordTarget.value = ""
      this.setBusy(false)
    }
  }

  async createPasskey(password) {
    // 本人確認 (現在のパスワード) に成功したときだけ challenge がもらえる
    const options = await this.postJSON(this.optionsUrlValue, { current_password: password })
    if (!options.ok) {
      this.setStatus(options.message)
      return
    }

    let credential = null
    try {
      credential = await navigator.credentials.create({ publicKey: parseCreationOptions(options.body) })
    } catch (error) {
      this.setStatus(this.creationErrorMessage(error))
      return
    }

    if (!credential) {
      this.setStatus("パスキーを作成できませんでした。")
      return
    }

    const result = await this.postJSON(this.urlValue, {
      credential: JSON.stringify(creationCredentialToJSON(credential)),
      nickname: this.nicknameTarget.value
    })

    if (!result.ok) {
      this.setStatus(result.message)
      return
    }

    // 成功したときだけ描き直す (上の一覧に新しい行を出すため)
    this.setStatus("パスキーを登録しました。")
    Turbo.visit(window.location.href, { action: "replace" })
  }

  creationErrorMessage(error) {
    // ユーザーがキャンセルした / 時間切れ。失敗として騒がない
    if (error.name === "NotAllowedError" || error.name === "AbortError") return ""
    // exclude に載っている認証器で作ろうとしたとき
    if (error.name === "InvalidStateError") return "この端末のパスキーはすでに登録されています。"

    return "この端末ではパスキーを作成できませんでした。"
  }

  // ---- サーバとのやりとり ----

  async postJSON(url, body) {
    let response = null

    try {
      response = await fetch(url, {
        method: "POST",
        headers: this.headers,
        credentials: "same-origin",
        body: JSON.stringify(body)
      })
    } catch (error) {
      return { ok: false, message: "通信できませんでした。電波の届くところでもう一度お試しください。" }
    }

    // セッションが切れると fetch がログイン画面へのリダイレクトに追従し、
    // 200 の HTML が返る (response.ok は true のまま)
    if (response.redirected || !this.isJson(response)) {
      return { ok: false, message: "ログインし直してから、もう一度お試しください。" }
    }

    const parsed = await response.json().catch(() => ({}))

    if (!response.ok) {
      return { ok: false, message: parsed.error || "パスキーを登録できませんでした。" }
    }

    return { ok: true, body: parsed }
  }

  // ---- 表示 ----

  setBusy(busy) {
    this.busy = busy
    this.submitTarget.disabled = busy
  }

  setStatus(text) {
    this.statusTarget.textContent = text
  }

  // ---- 環境の判定 ----

  get supported() {
    return typeof window.PublicKeyCredential === "function" &&
      !!(navigator.credentials && navigator.credentials.create)
  }

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
}
