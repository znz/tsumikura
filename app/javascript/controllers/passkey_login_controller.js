import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"
import { parseRequestOptions, requestCredentialToJSON } from "passkey_codec"

// パスキーでのログイン (docs/spec/05-auth.md 5 節)。ログイン画面で動く。
//
// discoverable credential なのでメールアドレスの入力は要らない。
// 対応ブラウザでは conditional UI (mediation: "conditional") を使い、メール欄を
// タップしたときに候補として出す。対応していなければ「パスキーでログイン」ボタンから。
//
// **未対応のブラウザではボタンを出さない** (サーバ側で hidden にしてあり、この controller が出す)。
// パスワードのフォームは常にそのまま使える。
//
// **ceremony は同時に 1 つしか始められない。** conditional とボタンが競合するので、
// 通し番号 (this.run) を持ち、後から始まったものだけが画面と遷移を触る。
export default class extends Controller {
  static targets = ["button", "status"]
  static values = { url: String, optionsUrl: String }

  connect() {
    this.run = 0
    this.abortController = null

    // Turbo のプレビュー (キャッシュからの先出し描画) では何もしない。
    // すぐ本物の描画で connect し直されるので、ceremony を二重に始めてしまう
    if (document.documentElement.hasAttribute("data-turbo-preview")) return
    if (!this.supported) return

    this.buttonTarget.hidden = false
    this.startConditional()
  }

  disconnect() {
    // Turbo で画面を離れたら ceremony を畳む (残すと次の get が失敗する)。
    // 走っている run を無効にしてから abort する
    this.run++
    this.abort()
  }

  // ---- conditional UI (メール欄に候補を出す) ----

  async startConditional({ retry = false } = {}) {
    if (typeof window.PublicKeyCredential.isConditionalMediationAvailable !== "function") return

    let available = false
    try {
      available = await window.PublicKeyCredential.isConditionalMediationAvailable()
    } catch (error) {
      return
    }

    // await の間に画面を離れていることがある
    if (!available || !this.element.isConnected) return

    await this.authenticate({ conditional: true, retry: retry })
  }

  // ---- ボタン ----

  async signIn(event) {
    event.preventDefault()

    const signedIn = await this.authenticate({ conditional: false })

    // キャンセルや失敗で戻ってきたら conditional UI を再開する
    // (再開しないと、メール欄の候補が二度と出ないまま残る)
    if (!signedIn && this.element.isConnected) this.startConditional()
  }

  // ---- 共通 ----

  // ログインまで進めたら true。それ以外 (キャンセル・失敗・後発に譲った) は false
  async authenticate({ conditional, retry = false }) {
    const run = ++this.run
    this.abort()
    if (!conditional) this.setStatus("パスキーを確認しています…")

    const options = await this.postJSON(this.optionsUrlValue, {})
    if (!this.current(run)) return false

    if (!options.ok) {
      if (!conditional) this.setStatus(options.message)
      return false
    }

    // fetch の間にボタンが押されていたら、ここまでで抜けている。
    // 念のため get の直前でも前の ceremony を畳む
    this.abort()
    const abortController = new AbortController()
    this.abortController = abortController

    let credential = null
    try {
      credential = await navigator.credentials.get({
        publicKey: parseRequestOptions(options.body),
        mediation: conditional ? "conditional" : "optional",
        signal: abortController.signal
      })
    } catch (error) {
      // キャンセル・中断・時間切れは静かに戻す。
      // **後発の ceremony に取って代わられているときは画面を触らない**
      // (中断された側の catch が、後発の「確認しています…」を消してしまう)
      if (this.current(run)) this.setStatus(conditional ? "" : this.getErrorMessage(error))
      return false
    } finally {
      if (this.abortController === abortController) this.abortController = null
    }

    if (!this.current(run)) return false

    if (!credential) {
      if (!conditional) this.setStatus("")
      return false
    }

    const result = await this.postJSON(this.urlValue, {
      credential: JSON.stringify(requestCredentialToJSON(credential))
    })
    if (!this.current(run)) return false

    if (!result.ok) {
      // challenge には有効期限がある。conditional UI はログイン画面を開いたまま待つので、
      // 期限切れ (401) で戻ってくることがある。**1 度だけ**取り直してやり直す
      // (失敗の応答は一様なので理由は分からない。無限に繰り返さないよう retry で止める)
      if (conditional && !retry) {
        this.startConditional({ retry: true })
        return false
      }

      this.setStatus(result.message)
      return false
    }

    // 成功したときだけ遷移する。行き先はサーバが決める (ログイン前に開こうとした URL)
    Turbo.visit(result.body.redirect_url || "/", { action: "replace" })
    return true
  }

  // この run がまだ「いちばん新しい ceremony」か
  current(run) {
    return run === this.run && this.element.isConnected
  }

  getErrorMessage(error) {
    if (error.name === "NotAllowedError" || error.name === "AbortError") return ""

    return "パスキーを読み取れませんでした。パスワードでログインしてください。"
  }

  abort() {
    if (!this.abortController) return

    this.abortController.abort()
    this.abortController = null
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

    // ログイン画面は未ログインで開くので通常はリダイレクトされないが、
    // 設定ミスなどで HTML が返ったときに成功と誤認しない
    if (response.redirected || !this.isJson(response)) {
      return { ok: false, message: "パスキーでログインできませんでした。パスワードでログインしてください。" }
    }

    const parsed = await response.json().catch(() => ({}))

    if (!response.ok) {
      return {
        ok: false,
        message: parsed.error || "パスキーでログインできませんでした。パスワードでログインしてください。"
      }
    }

    return { ok: true, body: parsed }
  }

  // ---- 表示 ----

  setStatus(text) {
    this.statusTarget.textContent = text
  }

  // ---- 環境の判定 ----

  get supported() {
    return typeof window.PublicKeyCredential === "function" &&
      !!(navigator.credentials && navigator.credentials.get)
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
