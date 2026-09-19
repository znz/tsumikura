class LotsController < ApplicationController
  # ロットの作成・編集・削除は必ず Stock::* のサービス経由で行う。
  # サービスの中で item.lock! + Stock::Recalculator がキャッシュを作り直す
  # (docs/spec/01-domain-model.md 判断 1)。

  # kind はフォームから変えられるのは作成時だけ (編集で由来をすり替えさせない)
  EDITABLE_ATTRIBUTES = %i[
    acquired_on expires_on initial_quantity pack_size pack_count price_yen store_id note
  ].freeze

  before_action :set_item, only: %i[ new create ]
  before_action :set_lot, only: %i[ edit update destroy ]
  before_action :set_stores, only: %i[ new create edit update ]

  def new
    @lot = @item.lots.new(default_attributes)
  end

  def create
    @lot = Stock::RecordPurchase.call(item: @item, user: Current.user, attributes: create_params)

    if @lot.persisted?
      redirect_to @item, notice: "「#{@item.name}」に#{helpers.lot_kind_label(@lot)}を記録しました。"
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if Stock::ReviseLot.call(@lot, update_params).errors.empty?
      redirect_to @item, notice: "「#{@item.name}」の#{helpers.lot_kind_label(@lot)}を更新しました。"
    else
      render :edit, status: :unprocessable_content
    end
  end

  # 使用・廃棄の記録が紐づくロットは削除できない (Lot#ensure_not_consumed)
  def destroy
    Stock::DeleteLot.call(@lot)

    if @lot.destroyed?
      redirect_to @item, status: :see_other,
        notice: "「#{@item.name}」の#{helpers.lot_kind_label(@lot)}を削除しました。"
    else
      redirect_to @item, status: :see_other, alert: @lot.errors.full_messages.to_sentence
    end
  end

  private
    def set_item
      @item = Item.find(params[:item_id])
    end

    # 画面から編集・削除できるのは購入と初期在庫のロットだけ。
    # 調整ロット (棚卸・自動補填が作る) は、元になった記録の側から直す
    def set_lot
      @lot = Lot.recordable.find(params[:id])
      @item = @lot.item
    end

    def set_stores
      @stores = Store.ordered
    end

    # 入数の初期値は品目の既定値。入数が分かっているときだけ「入数 × パック数」で始める
    def default_attributes
      { kind: :purchase, acquired_on: Date.current,
        pack_size: @item.default_pack_size, pack_count: (1 if @item.default_pack_size.present?) }
    end

    def create_params
      attributes = params.expect(lot: [ :kind, *EDITABLE_ATTRIBUTES ])
      # 画面から作れる由来は購入と初期在庫だけ。adjustment は棚卸 (Phase 9) と
      # 在庫不足時の自動補填 (Phase 8) が作る
      attributes[:kind] = "purchase" unless Lot::RECORDABLE_KINDS.include?(attributes[:kind])
      attributes
    end

    def update_params
      params.expect(lot: EDITABLE_ATTRIBUTES)
    end
end
