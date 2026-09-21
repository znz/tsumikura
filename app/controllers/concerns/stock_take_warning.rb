# 「直近の棚卸日より前の日付です」の警告 (docs/spec/01-domain-model.md 判断 1)。
#
# 残数は「符号付き数量の総和」なので、時系列上の途中在庫は再現しない。
# 直近の棚卸日より前の日付に記録を足すと理屈上は矛盾するので警告するが、
# **保存はブロックしない** (docs/spec/03-screens.md 5 節)。
#
# 棚卸は保管場所ごとなので、判定は**品目単位** (Item#last_counted_on) で行う。
# 全体の最終棚卸日で見ると「冷蔵庫を数えただけ」で洗剤の購入にも警告が出てしまい、
# 誤警告が多いと読まれなくなる。
#
# JS が無くても確実に出せるよう、保存後の notice に足す形にする。
# フォームには「この品目の直近の棚卸日」を添えて、入力の時点でも気づけるようにする
# (app/views/application/_stock_take_hint.html.erb)。
module StockTakeWarning
  extend ActiveSupport::Concern

  private
    def stock_take_warning(date, item)
      last = item&.last_counted_on
      return nil if date.blank? || last.blank? || date >= last

      "この記録の日付は「#{item.name}」を数えた直近の棚卸日 (#{I18n.l(last)}) より前です。" \
        "棚卸で合わせた在庫と食い違うことがあります。"
    end
end
