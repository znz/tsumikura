class ItemPurposesController < ApplicationController
  # 用途マスタは品目詳細配下 (docs/spec/03-screens.md 画面 9b)。
  # グローバルなマスタにはしない (docs/spec/01-domain-model.md 判断 4)。

  before_action :set_item
  before_action :set_purpose, only: %i[ edit update destroy ]

  def index
    @purposes = @item.item_purposes.active.ordered.includes(:usage_records).to_a
    @archived_purposes = @item.item_purposes.archived.ordered.to_a
  end

  def new
    @purpose = @item.item_purposes.new(default_quantity: 1)
  end

  def create
    @purpose = @item.item_purposes.new(purpose_params)

    if @purpose.save
      redirect_to item_purposes_path(@item), notice: "用途「#{@purpose.name}」を追加しました。"
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @purpose.update(purpose_params)
      redirect_to item_purposes_path(@item), notice: "用途「#{@purpose.name}」を更新しました。"
    else
      render :edit, status: :unprocessable_content
    end
  end

  # 使用記録が紐づく用途は削除できない (ItemPurpose#ensure_not_used)。
  # 履歴を消さないための守りで、代わりにアーカイブしてもらう
  def destroy
    if @purpose.destroy
      redirect_to item_purposes_path(@item), status: :see_other,
        notice: "用途「#{@purpose.name}」を削除しました。"
    else
      redirect_to item_purposes_path(@item), status: :see_other,
        alert: @purpose.errors.full_messages.to_sentence
    end
  end

  private
    def set_item
      @item = Item.find_by_param!(params[:item_id])
    end

    def set_purpose
      @purpose = @item.item_purposes.find_by_param!(params[:id])
    end

    # position は ItemPurposes::PositionsController、archived_at は
    # ItemPurposes::ArchivesController の担当なので受け取らない。
    # item_id は URL で決まる (他の品目に付け替えさせない)
    def purpose_params
      params.expect(item_purpose: [ :name, :default_quantity ])
    end
end
