module StorageLocations
  # 並べ替え (上へ / 下へ)。position を StorageLocationsController#update で permit しないために分ける
  class PositionsController < ApplicationController
    def update
      storage_location = StorageLocation.find(params[:storage_location_id])
      # 端まで来ている / 方向が不正なときは move! が false を返す
      storage_location.move!(params[:direction])

      redirect_to storage_locations_path, status: :see_other
    end
  end
end
