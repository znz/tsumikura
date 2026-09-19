# 名前・よみの正規化。`normalizes` に渡す lambda をここにまとめる。
module Normalizations
  # String#strip は半角の空白しか落とさないので、全角スペース (U+3000) も落とせる形で持つ。
  # 「洗面所」と「洗面所　」が別名として一意制約をすり抜けるのを防ぐ
  SURROUNDING_SPACE = /\A[[:space:]]+|[[:space:]]+\z/

  # 前後の空白 (全角スペースを含む) を落とす
  STRIP = ->(value) { value.gsub(SURROUNDING_SPACE, "") }

  # カタカナをひらがなにそろえる (長音符「ー」は範囲外なのでそのまま残る)。
  # よみの保存と検索語の両方に掛けて、「トイレ」で「といれっとぺーぱー」に当たるようにする
  TO_HIRAGANA = ->(value) { value.tr("ァ-ヶ", "ぁ-ゖ") }

  # よみ: 前後の空白を落としてひらがなにそろえ、空になったら nil にする
  READING = ->(value) { TO_HIRAGANA.call(STRIP.call(value)).presence }
end
