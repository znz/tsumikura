class DisposalsController < ApplicationController
  # 廃棄 (docs/spec/03-screens.md 1 節)。理由は 期限切れ / 破損 / 紛失 / その他。
  # 廃棄は kind: disposal の stock_movement 1 行が記録そのものなので、
  # 取り消しはその行の削除 (destroy) になる。
  #
  # 廃棄は消費に数えない (docs/spec/02-forecast.md 3 節)。

  include StockTakeWarning

  EDITABLE_ATTRIBUTES = %i[ quantity occurred_on lot_id disposal_reason note ].freeze

  before_action :set_item, only: %i[ new create ]
  # 取り消しは 2 台で同時に押されることがあるので、無くなっていても 404 にしない
  before_action :find_movement, only: :destroy

  def new
    # ロットの行からの「廃棄」リンクは GET なので lot_id は Base58 の 22 文字で来る。
    # フォームのセレクトの値は POST の本文にしか出ないので UUID のまま
    # (docs/spec/03-screens.md)。読めない値は「未指定」に倒す (FEFO の自動引き当て)
    @disposal = Disposal.new(quantity: 1, occurred_on: Date.current,
      lot_id: Base58Uuid.decode_or_nil(params[:lot_id]), disposal_reason: "expired")
    load_lots
  end

  def create
    @disposal = Stock::RecordDisposal.call(item: @item, user: Current.user,
      attributes: disposal_params)

    if @disposal.movements.present?
      redirect_with_toast
    else
      load_lots
      render :new, status: :unprocessable_content
    end
  end

  def destroy
    return redirect_to_already_removed if @movement.nil?

    Stock::DeleteDisposal.call(@movement)

    redirect_after_destroy notice: "「#{@item.name}」の廃棄の記録を取り消しました。"
  rescue ActiveRecord::RecordNotFound
    # ロック待ちの間に別の画面で消されていた
    redirect_to_already_removed
  end

  private
    def set_item
      @item = Item.find_by_param!(params[:item_id])
    end

    # 廃棄できるのは在庫の残っているロットだけ。捨てるのは古いものからなので
    # 期限切れを先に並べる
    def load_lots
      @lots = @item.lots.available.expired_first.to_a
    end

    def find_movement
      @movement = StockMovement.kind_disposal.find_by_param(params[:id])
      @item = @movement&.item
    end

    def disposal_params
      params.expect(disposal: EDITABLE_ATTRIBUTES)
    end

    # 使用記録と同じく「取り消し」付きのトーストで返す (レイアウトの #toasts が描く)。
    # 数量がロットをまたぐと movement が複数行になり 1 つの取り消し先に決められないので、
    # そのときだけボタンを出さず、品目詳細の「最近の記録」から消してもらう
    def redirect_with_toast
      flash[:toast] = recorded_notice
      flash[:undo_path] = disposal_path(@disposal.movements.first) if @disposal.movements.one?
      redirect_to item_path(@item), status: :see_other
    end

    def recorded_notice
      quantity = -@disposal.movements.sum(&:quantity)
      notice = "「#{@item.name}」を #{quantity} #{@item.unit} 廃棄しました。"
      unless @disposal.movements.one?
        notice += "#{@disposal.movements.size} つのロットに分かれたため、" \
          "取り消しは「最近の記録」から行ってください。"
      end

      "#{notice}#{stock_take_warning(@disposal.occurred_on, @item)}"
    end

    def redirect_after_destroy(**flash_options)
      redirect_back_or_to item_path(@item), status: :see_other, allow_other_host: false,
        **flash_options
    end

    def redirect_to_already_removed
      redirect_back_or_to items_path, status: :see_other, allow_other_host: false,
        alert: "この廃棄の記録はすでに取り消されています。"
    end
end
