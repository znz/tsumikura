import { Controller } from "@hotwired/stimulus"

// 購入入力の「入数 × パック数」/「直接入力」の切り替え (docs/spec/03-screens.md 画面 5)。
//
// JS が無い環境では切り替えボタンを出さず、入数・パック数・数量の入力欄をすべて出したまま
// 送信する。数量はサーバ側 (Lot#apply_pack_quantity) が
// 「入数とパック数がそろっていればその積、そうでなければ直接入力の数量」で決める。
// JS があるときだけ切り替えボタンを出し、使わない側の入力欄を disabled にして送らない。
export default class extends Controller {
  static targets = ["switcher", "mode", "pack", "direct", "hint"]

  connect() {
    this.switcherTarget.hidden = false
    this.hintTarget.hidden = true
    this.update()
  }

  update() {
    const checked = this.modeTargets.find((input) => input.checked)
    const mode = checked ? checked.value : "pack"

    this.toggle(this.packTarget, mode === "pack")
    this.toggle(this.directTarget, mode === "direct")
  }

  // 隠した側は disabled にして送信対象から外す (残っているとサーバ側の判定が拾ってしまう)
  toggle(group, active) {
    group.hidden = !active
    group.querySelectorAll("input").forEach((input) => {
      input.disabled = !active
    })
  }
}
