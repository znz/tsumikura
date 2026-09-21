class StoresController < ApplicationController
  before_action :set_store, only: %i[ edit update destroy ]

  def index
    @stores = Store.ordered
  end

  def new
    @store = Store.new
  end

  def create
    @store = Store.new(store_params)

    if @store.save
      redirect_to stores_path, notice: "店舗「#{@store.name}」を追加しました。"
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @store.update(store_params)
      redirect_to stores_path, notice: "店舗「#{@store.name}」を更新しました。"
    else
      render :edit, status: :unprocessable_content
    end
  end

  # 削除は nullify。購入の記録は消えず、店舗だけが外れる (docs/spec/01-domain-model.md 3 節)
  def destroy
    name = @store.name
    detached = @store.lots.count
    @store.destroy

    redirect_to stores_path, status: :see_other,
      notice: "店舗「#{name}」を削除しました。#{detached} 件の購入の記録から店舗が外れました。"
  end

  private
    def set_store
      @store = Store.find_by_param!(params[:id])
    end

    def store_params
      params.expect(store: [ :name, :note ])
    end
end
