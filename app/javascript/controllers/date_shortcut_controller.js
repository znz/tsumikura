import { Controller } from "@hotwired/stimulus"

// 使用日の「今日 / 昨日」ボタン (docs/spec/03-screens.md 画面 4)。
//
// JS が無い環境では日付ピッカー (input[type=date]) だけを出す。
// 既定は今日なので、JS 無しでも「今日使った」は 1 操作も要らない。
export default class extends Controller {
  static targets = ["input", "control"]

  connect() {
    this.controlTargets.forEach((control) => {
      control.hidden = false
    })
  }

  // data-date-shortcut-days-ago-param で「何日前か」を受け取る
  select(event) {
    const date = new Date()
    date.setDate(date.getDate() - Number(event.params.daysAgo))

    this.inputTarget.value = [
      date.getFullYear(),
      String(date.getMonth() + 1).padStart(2, "0"),
      String(date.getDate()).padStart(2, "0")
    ].join("-")
  }
}
