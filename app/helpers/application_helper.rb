module ApplicationHelper
  # 表示名に付ける敬称。家族の表示名は「おかあさん」のように敬称込みで登録されることが多いので、
  # すでに敬称で終わっているときは重ねない (「おかあさんさん」にしない)
  NAME_HONORIFICS = %w[ さん ちゃん くん さま 様 ].freeze

  def name_with_san(name)
    name = name.to_s.strip
    name.end_with?(*NAME_HONORIFICS) ? name : "#{name}さん"
  end

  # URL に出す id (Base58 の 22 文字)。レコードそのものがあれば to_param を使えばよいが、
  # id しか手元にないとき (関連を読み込まずに済ませたいとき) に使う。
  # **URL に出るのはここを通した値だけ**で、POST の本文に入る id は UUID のまま
  # (docs/spec/03-screens.md)
  def id_param(id)
    id && Base58Uuid.encode(id)
  end

  # フォームとボタンの見た目。タップ領域は 44px 以上 (min-h-11) を守る (docs/spec/03-screens.md)
  def field_classes(extra = nil)
    class_names("mt-2 block min-h-11 w-full rounded-lg border border-slate-300 px-3 py-2 shadow-sm focus:outline-blue-600", extra)
  end

  def label_classes(extra = nil)
    class_names("block text-sm font-medium text-slate-700", extra)
  end

  def hint_classes(extra = nil)
    class_names("mt-1 text-sm text-slate-500", extra)
  end

  def primary_button_classes(extra = nil)
    class_names("min-h-11 w-full cursor-pointer rounded-lg bg-blue-600 px-4 py-3 font-medium text-white hover:bg-blue-500", extra)
  end

  def secondary_button_classes(extra = nil)
    class_names("flex min-h-11 items-center justify-center rounded-lg border border-slate-300 px-3 text-sm text-slate-700 hover:bg-slate-50", extra)
  end

  def danger_button_classes(extra = nil)
    class_names("min-h-11 w-full cursor-pointer rounded-lg border border-red-300 px-4 py-3 text-sm font-medium text-red-700 hover:bg-red-50", extra)
  end

  # 各一覧の右上にある「〜を追加」リンク (主ボタンの小型版)
  def add_link_classes(extra = nil)
    class_names("flex min-h-11 items-center rounded-lg bg-blue-600 px-4 font-medium text-white hover:bg-blue-500", extra)
  end

  # 「使った」ボタン。片手で押せるよう 44px 以上を確保する (docs/spec/03-screens.md 画面 2 / 4b)
  def use_button_classes(extra = nil)
    class_names("flex min-h-11 cursor-pointer items-center justify-center rounded-lg bg-blue-600 px-4 font-medium text-white hover:bg-blue-500", extra)
  end

  # 下部タブの「品目」は、一覧だけでなく詳細やフォーム、品目配下の記録画面でもハイライトする
  ITEM_TAB_CONTROLLERS = %w[ items lots usage_records item_purposes disposals ].freeze
  # 下部タブの中央「記録」は、記録メニューと棚卸でハイライトする
  RECORD_TAB_CONTROLLERS = %w[ record_menus stock_takes ].freeze
  # 下部タブの「買い物」は、買い物リストと、そこから進むまとめ購入でハイライトする
  SHOPPING_TAB_CONTROLLERS = %w[ shopping_lists shopping_list_items purchases ].freeze

  def items_tab_current?
    tab_current?(ITEM_TAB_CONTROLLERS)
  end

  def record_tab_current?
    tab_current?(RECORD_TAB_CONTROLLERS)
  end

  def shopping_tab_current?
    tab_current?(SHOPPING_TAB_CONTROLLERS)
  end

  def tab_current?(controllers)
    controllers.any? do |name|
      controller_path == name || controller_path.start_with?("#{name}/")
    end
  end

  def user_role_label(user)
    t("enums.user.role.#{user.role}")
  end

  def item_estimation_mode_label(item)
    t("enums.item.estimation_mode.#{item.estimation_mode}")
  end

  # ロットの由来 (購入 / 初期在庫 / 調整)
  def lot_kind_label(lot)
    t("enums.lot.kind.#{lot.kind}")
  end

  # 在庫の記録の種別 (入庫 / 使用 / 調整 / 廃棄)。棚卸の調整は「棚卸」と出す
  def movement_kind_label(movement)
    return t("enums.stock_movement.kind.stock_take") if movement.stock_take_entry_id.present?

    t("enums.stock_movement.kind.#{movement.kind}")
  end

  def disposal_reason_label(movement)
    t("enums.stock_movement.disposal_reason.#{movement.disposal_reason}")
  end

  # 増減が一目で分かるよう符号を付ける (棚卸の調整は増にも減にもなる)
  def signed_quantity(movement)
    quantity = movement.quantity

    quantity.positive? ? "+#{quantity}" : "−#{quantity.abs}"
  end

  # 使用を記録するときのロット選択肢。期限で選ぶので期限を先に出す
  def lot_option_label(lot, item)
    expiry = lot.expires_on ? "期限 #{l(lot.expires_on)}" : "期限なし"

    "#{expiry} ・ 残り #{lot.remaining_quantity} #{item.unit} (#{l(lot.acquired_on)} 購入)"
  end

  # 棚卸の実数の入力値。検証エラーで描き直すときは送られた値を優先し (入力を失わせない)、
  # ふだんは保存済みの明細の実数を出す。
  # 壊れた形のパラメータ (counts[5]=abc など) で 500 にしないよう、Hash 以外はたどらない
  def stock_take_count_value(counts, entry, *keys)
    submitted = keys.reduce(counts) { |value, key| value.is_a?(Hash) ? value[key] : nil }

    submitted.is_a?(String) ? submitted : entry&.counted_quantity
  end

  # 確認画面 (下書き) は確定で実際に使われる「今の記録在庫」を見せ、
  # 確定済みは確定した時点の値をそのまま見せる
  def stock_take_expected(entry, live)
    live ? entry.current_expected_quantity : entry.expected_quantity
  end

  def stock_take_difference(entry, live)
    live ? entry.current_difference : entry.difference
  end

  # 棚卸の差分の表示 (増減が一目で分かるよう符号を付ける)
  def stock_take_difference_text(entry, difference)
    return "未入力" unless entry.counted?
    return "変化なし" if difference.zero?

    difference.positive? ? "+#{difference}" : "−#{difference.abs}"
  end

  # 単価の表示。10 円未満は四捨五入すると 0 円に潰れるので小数 1 桁で出す
  # (100 枚 30 円 → 0.3 円/枚。Lot.round_unit_price が Integer / Float で返し分ける)
  def unit_price_text(price_yen, unit)
    return nil if price_yen.nil?

    "#{number_to_currency(price_yen, precision: price_yen.is_a?(Integer) ? 0 : 1)}/#{unit}"
  end
end
