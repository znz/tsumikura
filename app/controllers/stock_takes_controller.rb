class StockTakesController < ApplicationController
  # 棚卸 (docs/spec/03-screens.md 画面 6)。
  # (1) 保管場所を選ぶ → (2) その場所の品目の実数を入れる (途中保存できる) →
  # (3) 確認画面で差分サマリ → (4) 確定 (StockTakes::FinalizationsController)。
  #
  # 下書きの間は在庫にいっさい触らない。在庫を動かすのは確定だけ。
  # 確定済みの棚卸は編集・削除できないので、edit / update / destroy は drafts から引く
  # (調整ロットの編集が 404 になるのと同じ流儀)。

  # 棚卸日・保管場所は作成時だけ決める。finalized_at / user_id / expected_quantity /
  # difference はフォームから変更させない
  CREATE_ATTRIBUTES = %i[ counted_on storage_location_id note ].freeze

  before_action :set_stock_take, only: :show
  before_action :set_draft, only: %i[ edit update destroy ]
  before_action :set_storage_locations, only: %i[ new create ]

  def index
    @drafts = StockTake.drafts.includes(:storage_location, :user).recent_first
    @finalized = StockTake.finalized.includes(:storage_location, :user).recent_first
  end

  def show
    load_entries
  end

  def new
    @stock_take = StockTake.new(counted_on: Date.current)
  end

  def create
    @stock_take = StockTake.new(stock_take_params)
    @stock_take.user = Current.user

    if @stock_take.save
      redirect_to edit_stock_take_path(@stock_take),
        notice: "「#{@stock_take.storage_location_name}」の棚卸を始めます。"
    else
      render :new, status: :unprocessable_content
    end
  end

  # 実数の入力。明細は「入力された品目のぶんだけ」作るので、
  # 開いただけでは行を作らない (未入力 = 明細なし = 確定でスキップ)
  def edit
    load_target_rows
  end

  def update
    if Stock::WriteStockTakeEntries.call(@stock_take, counts: count_params)
      redirect_after_update
    else
      # 入力を失わせないよう、送られた値のまま描き直す
      @submitted_counts = count_params
      load_target_rows
      flash.now[:alert] = "実数は 0 以上の整数で入れてください。"
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    # 確定済みかの判定はロックの「あと」でなければ意味がない
    # (確定と削除が同時に走ると、確定済みの棚卸が消えてしまう)
    ApplicationRecord.transaction do
      @stock_take.lock!
      raise ActiveRecord::RecordNotFound if @stock_take.finalized?

      @stock_take.destroy
    end

    if @stock_take.destroyed?
      redirect_to stock_takes_path, status: :see_other, notice: "棚卸の下書きを削除しました。"
    else
      redirect_to stock_take_path(@stock_take), status: :see_other,
        alert: @stock_take.errors.full_messages.to_sentence
    end
  end

  private
    def set_stock_take
      @stock_take = StockTake.find(params[:id])
    end

    # 確定済みは編集も削除もできない (docs/spec/01-domain-model.md 3 節)
    def set_draft
      @stock_take = StockTake.drafts.find(params[:id])
    end

    def set_storage_locations
      @storage_locations = StorageLocation.ordered
    end

    def stock_take_params
      params.expect(stock_take: CREATE_ATTRIBUTES)
    end

    # 品目 id / ロット id をキーにした実数のハッシュ。
    # 数字にならないキーは無視する (壊れたパラメータで 500 にしない)
    def count_params
      counts = params[:counts]
      counts.is_a?(ActionController::Parameters) ? counts.to_unsafe_h : {}
    end

    # 確認画面 (差分サマリ) に進むか、そのまま数え続けるか
    def redirect_after_update
      if params[:continue].present?
        redirect_to edit_stock_take_path(@stock_take), notice: "途中まで保存しました。"
      else
        redirect_to stock_take_path(@stock_take)
      end
    end

    # 確認画面 (下書き) は「今の記録在庫」で差分を見せる。確定は確定時点の記録在庫で
    # 取り直すので、数えたあとに使用・購入があると下書き時点の差分とは食い違う。
    # 確定済みは、確定した時点の値をそのまま見せる
    def load_entries
      @entries = @stock_take.stock_take_entries.includes(:item, :lot).ordered.to_a
      @live = !@stock_take.finalized?
      differences = @entries.filter_map { |entry| stock_take_difference(entry) }

      @counted_count = @entries.count(&:counted?)
      @increased_count = differences.count(&:positive?)
      @decreased_count = differences.count(&:negative?)
    end

    # 画面と同じ判断でサマリを数える (ビューヘルパーと 1 か所にそろえる)
    def stock_take_difference(entry)
      @live ? entry.current_difference : entry.difference
    end

    # 数える対象の品目と、そのロット・入力済みの明細。
    # 品目が増えてもクエリ数が増えないよう、まとめて読んでから組み立てる。
    # すでにロット別に数えたロットは、使い切られて残 0 になっても欄を出し続ける
    # (欄が消えると、その明細を直すことも確かめることもできなくなる)
    def load_target_rows
      @items = @stock_take.target_items.to_a
      entries = @stock_take.stock_take_entries.to_a
      counted_lot_ids = entries.filter_map(&:lot_id)
      lots = Lot.where(item_id: @items.map(&:id)).available
        .or(Lot.where(id: counted_lot_ids)).fefo.to_a

      @entries_by_key = entries.index_by { |entry| [ entry.item_id, entry.lot_id ] }
      @lots_by_item_id = lots.group_by(&:item_id)
    end
end
