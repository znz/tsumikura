class UsageRecordsController < ApplicationController
  # 使用記録の作成・編集・削除は必ず Stock::* のサービス経由で行う。
  # サービスの中で item.lock! + FEFO の引き当て + Stock::Recalculator が動く
  # (docs/spec/01-domain-model.md 判断 1 / 5 節)。

  # 品目・記録者はフォームから受け取らない (URL とログイン中のユーザーで決まる)
  EDITABLE_ATTRIBUTES = %i[ quantity used_on item_purpose_id lot_id note ].freeze

  before_action :set_item, only: %i[ new create ]
  before_action :set_usage_record, only: %i[ edit update ]
  # 取り消しは 2 台で同時に押されることがあるので、無くなっていても 404 にしない
  before_action :find_usage_record, only: :destroy
  before_action :set_form_options, only: %i[ new create edit update ]

  def new
    @usage_record = @item.usage_records.new(quantity: 1, used_on: Date.current)
  end

  def create
    @usage_record = Stock::RecordUsage.call(item: @item, user: Current.user,
      attributes: usage_record_params)

    if @usage_record.persisted?
      redirect_to @item, notice: recorded_notice(@usage_record)
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if Stock::ReviseUsage.call(@usage_record, usage_record_params).errors.empty?
      redirect_to @item, notice: revised_notice(@usage_record)
    else
      render :edit, status: :unprocessable_content
    end
  end

  # ワンタップ使用の「取り消し」もここを通る。押した画面に戻したいので referer を使う
  def destroy
    return redirect_to_already_removed if @usage_record.nil?

    Stock::DeleteMovement.call(@usage_record)

    if @usage_record.destroyed?
      redirect_after_destroy notice: "「#{@item.name}」の使用の記録を取り消しました。"
    else
      redirect_after_destroy alert: @usage_record.errors.full_messages.to_sentence
    end
  rescue ActiveRecord::RecordNotFound
    # ロック待ちの間に別の画面で消されていた
    redirect_to_already_removed
  end

  private
    def set_item
      @item = Item.find(params[:item_id])
    end

    def set_usage_record
      @usage_record = UsageRecord.find(params[:id])
      @item = @usage_record.item
    end

    def find_usage_record
      @usage_record = UsageRecord.find_by(id: params[:id])
      @item = @usage_record&.item
    end

    # 用途チップは用途を管理する品目だけ、ロットの選択は期限を管理する品目だけに出す
    # (docs/spec/03-screens.md 画面 4)
    def set_form_options
      @purposes = purpose_options
      @lots = @item.tracks_expiry? ? @item.lots.available.fefo.to_a : []
    end

    # 編集中の記録に付いている用途がアーカイブ済みでも、選択肢から消さない
    # (消すと「用途なし」に付け替わってしまう)
    def purpose_options
      return [] unless @item.tracks_purposes?

      purposes = @item.item_purposes.active.ordered.to_a
      current = @usage_record&.item_purpose
      current.present? && current.archived? ? purposes + [ current ] : purposes
    end

    def usage_record_params
      params.expect(usage_record: EDITABLE_ATTRIBUTES)
    end

    # 削除した記録の画面 (編集フォーム / 検証エラーの再描画) に戻すと 404 になるので品目詳細へ。
    # /usage_records/5 と /usage_records/50 を取り違えないよう区切りまで見る
    def from_record_page?
      path = URI(request.referer.to_s).path.to_s
      base = usage_record_path(@usage_record)

      path == base || path.start_with?("#{base}/")
    rescue URI::InvalidURIError
      false
    end

    def redirect_after_destroy(**flash_options)
      if from_record_page?
        redirect_to item_path(@item), status: :see_other, **flash_options
      else
        redirect_back_or_to item_path(@item), status: :see_other, allow_other_host: false,
          **flash_options
      end
    end

    def redirect_to_already_removed
      redirect_back_or_to items_path, status: :see_other, allow_other_host: false,
        alert: "この使用の記録はすでに取り消されています。"
    end

    # 在庫記録が足りなくても記録は成功させる (設計原則 3)。
    # 黙って在庫を作ると気づけないので、補填したことは必ず伝える
    def recorded_notice(usage_record)
      notice = "「#{@item.name}」を #{usage_record.quantity} #{@item.unit} 使いました。"

      "#{notice}#{allocation_notice(usage_record)}"
    end

    def revised_notice(usage_record)
      notice = "「#{@item.name}」の使用の記録を更新しました。"

      "#{notice}#{allocation_notice(usage_record)}"
    end

    # 引き当てで「言われたとおりにできなかった」ことは必ず伝える
    def allocation_notice(usage_record)
      messages = []
      compensated = usage_record.compensated_quantity.to_i
      if compensated.positive?
        messages << "在庫記録が不足していたため #{compensated} #{@item.unit} を調整しました。"
      end
      if usage_record.preferred_lot_unavailable
        messages << "指定したロットは使い切られていたため、ほかのロットから引きました。"
      end

      messages.join
    end
end
