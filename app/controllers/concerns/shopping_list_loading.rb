# 買い物リストの読み込み (docs/spec/03-screens.md 画面 7)。
#
# ShoppingListsController#show と、入力エラーで一覧を描き直す ShoppingListItemsController が
# 同じ組み立てを共有するためにここにまとめる。
module ShoppingListLoading
  extend ActiveSupport::Concern

  included do
    before_action :set_today
  end

  private
    # today は 1 リクエストにつき 1 回だけ取る (docs/spec/02-forecast.md 14 節)。
    # 0 時をまたぐ瞬間に開いても、1 画面の中で基準日がずれないようにする
    def set_today
      @today = Date.current
    end

    # 一覧は読むだけで書かない (GET に副作用を出さない。判断 5)
    def load_shopping_list
      @list = ShoppingLists::Builder.call(today: @today)
      @new_entry ||= ShoppingListItem.new
    end
end
