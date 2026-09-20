# 買い物リストの行の操作先 (docs/spec/03-screens.md 画面 7)。
#
# 行はまだ永続化されていないことがある (自動で並んでいるだけの行)。
# 永続行があればその行を更新 (PATCH)、無ければ作成 (POST) に送り、
# コントローラ側が find_or_initialize_by(item_id:) で行を用意する。
module ShoppingListsHelper
  def shopping_list_row_url(row)
    row.record_id ? shopping_list_item_path(row.record_id) : shopping_list_items_path
  end

  def shopping_list_row_method(row)
    row.record_id ? :patch : :post
  end

  # button_to に渡す method と hidden field。
  # 操作は「この状態にする」を明示して送る (トグルにすると古い画面からの操作で反転する)
  def shopping_list_row_options(row, **state)
    { method: shopping_list_row_method(row),
      params: { shopping_list_item: shopping_list_row_state(row, **state) } }
  end

  def shopping_list_row_state(row, **state)
    row.record_id ? state : state.merge(item_id: row.item_id)
  end

  # まとめ購入の入力欄の名前 (purchase[lines][<行の id>][<属性>])
  def purchase_line_field_name(line, attribute)
    "purchase[lines][#{line.record.id}][#{attribute}]"
  end

  def purchase_line_field_id(line, attribute)
    "purchase_line_#{line.record.id}_#{attribute}"
  end
end
