class CategoriesController < ApplicationController
  before_action :set_category, only: %i[ edit update destroy ]

  def index
    @categories = Category.ordered
    @item_counts = Item.where.not(category_id: nil).group(:category_id).count
  end

  def new
    @category = Category.new
  end

  def create
    @category = Category.new(category_params)

    if @category.save
      redirect_to categories_path, notice: "カテゴリ「#{@category.name}」を追加しました。"
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @category.update(category_params)
      redirect_to categories_path, notice: "カテゴリ「#{@category.name}」を更新しました。"
    else
      render :edit, status: :unprocessable_content
    end
  end

  # 削除は nullify。品目は消えず、カテゴリだけが外れる (docs/spec/01-domain-model.md 3 節)
  def destroy
    name = @category.name
    detached = @category.items.count
    @category.destroy

    redirect_to categories_path, status: :see_other,
      notice: "カテゴリ「#{name}」を削除しました。#{detached} 件の品目からカテゴリが外れました。"
  end

  private
    def set_category
      @category = Category.find(params[:id])
    end

    # position は Categories::PositionsController の担当なので受け取らない
    def category_params
      params.expect(category: [ :name ])
    end
end
