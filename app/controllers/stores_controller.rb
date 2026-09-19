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

  # 店舗を参照するのは購入記録 (lots) で、Phase 7 で追加する。
  # そのときに dependent: :nullify と「n 件の購入記録から外れます」の確認を足す
  def destroy
    name = @store.name
    @store.destroy

    redirect_to stores_path, status: :see_other, notice: "店舗「#{name}」を削除しました。"
  end

  private
    def set_store
      @store = Store.find(params[:id])
    end

    def store_params
      params.expect(store: [ :name, :note ])
    end
end
