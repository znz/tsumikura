# UUID (128 ビット) と Base58 の 22 文字を相互に変換する。
#
# アプリの主キーは UUIDv7 (docs/spec/01-domain-model.md) だが、URL にそのまま出すと
# 36 文字で長く読みにくいので、パスと GET のクエリでは Base58 の 22 文字で表す
# (docs/spec/03-screens.md)。
#
# Rails にも DB にも依存しない純粋な関数だけを置く (spec_helper だけで回せるように)。
# モデル側の to_param / ファインダは app/models/concerns/base58_param.rb。
module Base58Uuid
  # Bitcoin と同じアルファベット。見間違えやすい 0 O I l を抜いてある。
  # **ASCII の昇順**に並んでいるので、Base58 文字列の辞書順は UUID の大小と一致する
  # (UUIDv7 は時刻順なので、URL の文字列をそのまま並べても作成順になる)
  ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".freeze

  # 58**22 > 2**128 なので、22 文字あれば必ず表せる。
  # **長さは常に 22 で固定**し、足りないぶんは先頭を "1" (= 0) で埋める。
  # 可変長にすると 1 つの UUID に複数の表現ができてしまい、URL が一意にならない
  LENGTH = 22

  # ハイフンつきの正規形 (8-4-4-4-12)。**小文字の 16 進だけ**を通す。
  # PostgreSQL の uuid 型は大文字小文字を区別しないので、\h にすると
  # 「検証は通るのに Ruby 側の文字列比較では一致しない」値ができてしまう
  # (Stock::Allocator の `lot.id == preferred_lot_id` や
  #  Stock::WriteStockTakeEntries の `ids.include?(id)` が静かに外れ、
  #  改ざんしたフォームで「指定したロットは使い切り」扱いにできた)。
  # POST の本文に入る UUID はアプリが描いた小文字だけなので、大文字は 422 / 無視でよい。
  # decode もこの形で返す
  FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  # ハイフンを抜いた 32 桁。Integer(hex, 16) はアンダースコアや "0x" や前後の空白を
  # 受け付けてしまうので、**先に正規表現で弾いてから** to_i(16) する
  HEX_FORMAT = /\A\h{32}\z/

  # encode が受け付ける形。DB から読んだ値を URL にするだけなので大文字も許すが、
  # **ハイフンの位置は正規形どおり**でなければならない (delete("-") は位置を見ないので、
  # "0-1-99bb1c…" のような形を先に弾く)
  ENCODABLE_FORMAT = /\A(?:\h{8}-\h{4}-\h{4}-\h{4}-\h{12}|\h{32})\z/

  MAX = (1 << 128) - 1

  INDEX = ALPHABET.each_char.with_index.to_h.freeze

  # 主キーが UUID でない DB (UUIDv7 化する前の bigint) にこのコードを当てたときに投げる。
  # migration のバージョン番号は変えていないので `db:migrate` / `db:prepare` は
  # 「未適用なし」で成功してしまい、気づかないまま全画面が 500 になる。
  # 原因がすぐ分かるメッセージにするための保険 (docs/ops/deployment.md 10 節)
  class NotUuidPrimaryKey < StandardError; end

  NOT_UUID_PRIMARY_KEY_MESSAGE =
    "主キーが UUID ではありません (%s)。UUIDv7 化より前の DB にこのコードを当てています。" \
    "DB を作り直してください (docs/ops/development.md 3 節 / docs/ops/deployment.md 10 節)".freeze

  module_function

  # UUID (正規形のハイフンつき、またはハイフン無しの 32 桁。大文字小文字どちらでも)
  # → Base58 の 22 文字
  def encode(uuid)
    raise ArgumentError, "UUID must be a String, got #{uuid.class}" unless uuid.is_a?(String)
    raise ArgumentError, "Invalid UUID: #{uuid.inspect}" unless ENCODABLE_FORMAT.match?(uuid)

    num = uuid.delete("-").to_i(16)
    encoded = Array.new(LENGTH, ALPHABET[0])
    position = LENGTH - 1

    while num > 0
      num, remainder = num.divmod(58)
      encoded[position] = ALPHABET[remainder]
      position -= 1
    end

    encoded.join
  end

  # Base58 の 22 文字 → ハイフンつきの UUID (小文字)。
  # 22 文字ちょうどでない値・Base58 にない文字・128 ビットに収まらない値は ArgumentError
  def decode(encoded)
    unless encoded.is_a?(String) && encoded.length == LENGTH
      raise ArgumentError, "Base58 UUID must be #{LENGTH} characters, got #{encoded.inspect}"
    end

    num = encoded.each_char.inject(0) do |sum, char|
      index = INDEX[char]
      raise ArgumentError, "Invalid Base58 character #{char.inspect} in #{encoded.inspect}" if index.nil?

      sum * 58 + index
    end
    raise ArgumentError, "#{encoded.inspect} does not fit in 128 bits" if num > MAX

    format_uuid(num.to_s(16).rjust(32, "0"))
  end

  # 不正な値を「指定なし」に倒したいところ (一覧の絞り込みなど) 用。例外にせず nil を返す
  def decode_or_nil(encoded)
    decode(encoded)
  rescue ArgumentError
    nil
  end

  # UUID の形 (ハイフンつきの正規形・小文字) か。フォームから来た id の検証に使う
  def uuid?(value)
    value.is_a?(String) && FORMAT.match?(value)
  end

  # 主キーを URL の id にする (ApplicationRecord#to_param)。
  # UUID でない id を渡されたら「DB を作り直してください」と分かる例外にする。
  # encode をそのまま呼ぶと "UUID must be a String, got Integer" になり、
  # 原因 (bigint のままの DB) にたどり着けない
  def encode_primary_key(id)
    encode(id)
  rescue ArgumentError
    raise NotUuidPrimaryKey, format(NOT_UUID_PRIMARY_KEY_MESSAGE, id.inspect)
  end

  def format_uuid(hex)
    "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
  end
  private_class_method :format_uuid
end
