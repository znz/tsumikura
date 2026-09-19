import { Controller } from "@hotwired/stimulus"

// 取り消し付きトーストの自動消去 (docs/spec/03-screens.md 画面 4b)。
//
// JS が無い環境では消えないだけで、文言も「取り消し」ボタンもそのまま使える
// (次の画面遷移で flash ごと消える)。
export default class extends Controller {
  static values = { delay: { type: Number, default: 8000 } }

  connect() {
    this.timeout = setTimeout(() => this.element.remove(), this.delayValue)
  }

  disconnect() {
    clearTimeout(this.timeout)
  }
}
