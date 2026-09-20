class ItemsController < ApplicationController
  include ItemDetails

  # 一覧の状態フィルタ。既定はアーカイブ済みを隠した「有効な品目だけ」
  STATUSES = %w[ active archived all ].freeze
  DEFAULT_STATUS = "active".freeze
  # ダッシュボードのアラートカードからの絞り込み (docs/spec/03-screens.md 画面 1)。
  # 値は Forecast::Result#status / Expiry::Result#status と同じ名前にする
  PURCHASE_STATUSES = %w[ urgent soon ].freeze
  EXPIRY_STATUSES = %w[ expired expiring_soon ].freeze

  before_action :set_item, only: %i[ show edit update ]
  before_action :set_master_options, only: %i[ index new create edit update ]

  def index
    # 壊れた値 (配列・ハッシュ・数字でない文字列) は「指定なし」に倒す。
    # 0 件にして「品目が無い」ように見せるより、絞り込まない方が親切
    @query = params[:q].is_a?(String) ? params[:q] : ""
    @category_id = filter_id(params[:category_id])
    @storage_location_id = filter_id(params[:storage_location_id])
    @status = STATUSES.include?(params[:status]) ? params[:status] : DEFAULT_STATUS
    @purchase_status = PURCHASE_STATUSES.include?(params[:purchase]) ? params[:purchase] : nil
    @expiry_status = EXPIRY_STATUSES.include?(params[:expiry]) ? params[:expiry] : nil

    # 「今日」は 1 リクエストにつき 1 回だけ取る (0 時をまたいで予測と期限がずれないように)
    @today = Date.current
    items = filtered_items.includes(:category, :storage_location).ordered.to_a
    # 行ごとにステータスバッジを出すので、予測と期限はまとめて引く (品目が増えてもクエリは増えない)
    @forecasts = Forecast::BatchForecaster.call(items, today: @today)
    @expiries = Expiry::Evaluator.call(items, today: @today)
    @items = filtered_by_alert(items)
  end

  # 在庫・ロット・用途・最近の記録は ItemDetails が読む
  # (ワンタップ使用の Turbo Stream 応答と同じ描画を使うため)
  def show
    load_item_detail(@item)
  end

  def new
    @item = Item.new
  end

  def create
    @item = Item.new(item_params)

    if @item.save
      redirect_to @item, notice: "「#{@item.name}」を登録しました。"
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @item.update(item_params)
      redirect_to @item, notice: "「#{@item.name}」を更新しました。"
    else
      render :edit, status: :unprocessable_content
    end
  end

  private
    def set_item
      @item = Item.find(params[:id])
    end

    # 絞り込みの id。セレクトの選択状態を保つため整数にそろえ、
    # 正の整数でなければ「指定なし」として扱う
    def filter_id(value)
      return nil unless value.is_a?(String)

      id = Integer(value, 10, exception: false)
      id if id&.positive?
    end

    # 一覧の絞り込みセレクトと、フォームのカテゴリ / 保管場所セレクトの選択肢
    def set_master_options
      @categories = Category.ordered
      @storage_locations = StorageLocation.ordered
    end

    def filtered_items
      scope =
        case @status
        when "archived" then Item.archived
        when "all"      then Item.all
        else                 Item.active
        end

      scope.search(@query).in_category(@category_id).in_storage_location(@storage_location_id)
    end

    # 要購入・期限での絞り込みは、まとめて引いた判定結果を使って Ruby 側で行う
    # (SQL に予測の式を持ち込まないため。家庭用なので品目は数百件までで、ページネーションも無い)。
    # アーカイブ済みの品目は BatchForecaster が判定しないので、この絞り込みには出てこない
    def filtered_by_alert(items)
      items = items.select { |item| @forecasts[item.id]&.status.to_s == @purchase_status } if @purchase_status
      items = items.select { |item| @expiries[item.id]&.status.to_s == @expiry_status } if @expiry_status
      items
    end

    # archived_at は Items::ArchivesController の担当。
    # current_quantity / tracking_started_on / last_consumed_on は台帳から再計算される
    # キャッシュ列 (Phase 7 の Stock::Recalculator) なので、フォームからは受け取らない
    def item_params
      params.expect(item: [
        :name, :name_reading, :category_id, :storage_location_id, :unit,
        :default_pack_size, :minimum_quantity, :tracks_expiry, :tracks_purposes,
        :estimation_mode, :manual_interval_days,
        :soon_threshold_days, :urgent_threshold_days, :expiry_warning_days,
        :favorite, :note
      ])
    end
end
