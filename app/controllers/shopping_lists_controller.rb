class ShoppingListsController < ApplicationController
  # 買い物リスト (docs/spec/03-screens.md 画面 7)。
  # 一覧 = 「要購入判定が urgent / soon の品目 (導出)」∪「shopping_list_items の行」。
  # 開いただけでは行を作らない (チェック操作が来たときに ShoppingListItemsController が作る)。

  include ShoppingListLoading

  def show
    load_shopping_list
  end
end
