import { Controller } from "@hotwired/stimulus"

// 税別の単価・個数・税率から金額 (税込) を計算する入力補助
// (docs/spec/03-screens.md 画面 5 / 5b、docs/spec/01-domain-model.md 判断 6)。
//
// JS が無い環境では何もしない。3 項目はそのまま送られ、サーバ側 (Lot#apply_ex_tax_price) が
// 金額 (税込) が空のときだけ、保存の直前に同じ式で計算する。
// JS があるときは 3 項目がそろった時点で金額の欄を埋め、送信前に結果を見せる。
// 金額の欄は手で直せる (レシート全体の端数処理とは 1 円ずれることがある) ので、
// 「直前に自分が埋めた値」のままのときだけ書き換え・消去し、手で入れた値は触らない。
export default class extends Controller {
  static targets = ["total", "unitPrice", "count", "rate"]

  connect() {
    this.filled = null
    const total = this.compute()
    if (total === null) return

    const current = this.totalTarget.value
    // 検証エラーで描き直したとき、サーバは金額の欄を空のまま返す (計算は保存の直前にしか
    // しない)。3 項目がそろっていれば、ここで埋めて金額を見せる
    if (current === "") this.totalTarget.value = String(total)
    // 金額が 3 項目から計算した値と同じなら、自分が埋めた値として扱う (3 項目を直したら追従させる)
    if (this.totalTarget.value === String(total)) this.filled = this.totalTarget.value
  }

  calculate() {
    const total = this.compute()
    const current = this.totalTarget.value

    // 手で入れた金額が勝つ (サーバ側の「金額 (税込) が入っていればそちらを使う」とそろえる)
    if (current !== "" && current !== this.filled) return

    if (total === null) {
      // 3 項目が不完全になった。自分が埋めた値だけを空に戻す
      if (this.filled !== null) this.totalTarget.value = ""
      this.filled = null
      return
    }

    this.totalTarget.value = String(total)
    this.filled = this.totalTarget.value
  }

  // 1 円未満は切り捨て。浮動小数の誤差が出ないよう、税率は % のまま整数で掛けてから割る
  // (100 * 1.1 = 110.00000000000001 にしない)。サーバ側と同じ式
  compute() {
    const unit = this.integerValue(this.unitPriceTarget, 0)
    const count = this.integerValue(this.countTarget, 1)
    const checked = this.rateTargets.find((input) => input.checked)
    const rate = checked ? this.integerValue(checked, 0) : null

    if (unit === null || count === null || rate === null) return null

    return Math.floor(unit * count * (100 + rate) / 100)
  }

  // 空・小数・負 (min 未満) は null。ブラウザは数字でない入力を value = "" にする
  integerValue(input, min) {
    const value = input.value.trim()
    if (!/^\d+$/.test(value)) return null

    const number = Number(value)
    return Number.isSafeInteger(number) && number >= min ? number : null
  }
}
