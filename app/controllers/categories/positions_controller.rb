module Categories
  # 並べ替え (上へ / 下へ)。position を CategoriesController#update で permit しないために分ける
  class PositionsController < ApplicationController
    def update
      category = Category.find_by_param!(params[:category_id])
      # 端まで来ている / 方向が不正なときは move! が false を返す。
      # 並べ替えは失敗しても困らないので、どちらでも一覧に戻る
      category.move!(params[:direction])

      redirect_to categories_path, status: :see_other
    end
  end
end
