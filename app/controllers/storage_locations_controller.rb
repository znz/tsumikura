class StorageLocationsController < ApplicationController
  before_action :set_storage_location, only: %i[ edit update destroy ]

  def index
    @storage_locations = StorageLocation.ordered
    @item_counts = Item.where.not(storage_location_id: nil).group(:storage_location_id).count
  end

  def new
    @storage_location = StorageLocation.new
  end

  def create
    @storage_location = StorageLocation.new(storage_location_params)

    if @storage_location.save
      redirect_to storage_locations_path, notice: "保管場所「#{@storage_location.name}」を追加しました。"
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @storage_location.update(storage_location_params)
      redirect_to storage_locations_path, notice: "保管場所「#{@storage_location.name}」を更新しました。"
    else
      render :edit, status: :unprocessable_content
    end
  end

  # 削除は nullify。品目は消えず、保管場所だけが外れる (docs/spec/01-domain-model.md 3 節)
  def destroy
    name = @storage_location.name
    detached = @storage_location.items.count
    @storage_location.destroy

    redirect_to storage_locations_path, status: :see_other,
      notice: "保管場所「#{name}」を削除しました。#{detached} 件の品目から保管場所が外れました。"
  end

  private
    def set_storage_location
      @storage_location = StorageLocation.find(params[:id])
    end

    # position は StorageLocations::PositionsController の担当なので受け取らない
    def storage_location_params
      params.expect(storage_location: [ :name ])
    end
end
