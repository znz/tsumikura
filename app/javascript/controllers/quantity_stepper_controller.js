import { Controller } from "@hotwired/stimulus"

// 使用記録の数量の「+ / −」と、用途を選んだときの既定数量
// (docs/spec/03-screens.md 画面 4)。
//
// JS が無い環境では数値入力だけを出す (ボタンは hidden のまま)。
// 既定数量は、数量を空で送ればサーバ側 (UsageRecord#apply_default_quantity) が同じ値を補う。
export default class extends Controller {
  static targets = ["input", "control"]
  static values = { min: { type: Number, default: 1 } }

  connect() {
    this.controlTargets.forEach((control) => {
      control.hidden = false
    })
  }

  step(event) {
    const by = Number(event.params.by)
    const current = Number(this.inputTarget.value)
    const next = (Number.isFinite(current) ? current : this.minValue) + by

    this.inputTarget.value = Math.max(this.minValue, next)
  }

  // 用途のラジオから「この用途の既定数量」を受け取る
  useDefault(event) {
    const value = Number(event.params.default)
    if (!Number.isFinite(value) || value < this.minValue) return

    this.inputTarget.value = value
  }
}
