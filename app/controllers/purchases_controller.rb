class PurchasesController < ApplicationController
  # まとめ購入 (docs/spec/03-screens.md 画面 5b)。
  # 買い物リストのチェック済み行を並べ、店舗と購入日を共通にして 1 トランザクションで記録する。
  # 記録は必ず Stock::RecordPurchase を通す (入庫 = ロット + movement + キャッシュ再計算)。

  include ShoppingListLoading

  # 行ごとに入れる値 (購入日・店舗は共通)
  LINE_KEYS = %w[ initial_quantity pack_size pack_count price_yen expires_on ].freeze

  # 8 バイト整数の上限。これを超える id を where に渡すと PG が範囲エラーを返して 500 になる
  MAX_ID = 2**63 - 1

  NO_CHECKED_MESSAGE = "買い物リストでチェックした品目がありません。".freeze
  # 自由入力は品目が無いので在庫に記録できない。チェックを外すか、リストから外してもらう
  FREE_TEXT_ONLY_MESSAGE =
    "チェックされているのは自由入力の行だけです。自由入力は在庫に記録できないので、" \
    "買い終えたら「リストから外す」で消してください。".freeze
  STALE_MESSAGE =
    "チェックした品目はすでに購入済みです (ほかの人が先に記録したか、チェックが外されました)。".freeze

  before_action :set_stores

  def new
    list = ShoppingLists::Builder.call(today: @today)
    rows = list.checked_item_rows
    @free_text_entries = checked_free_text_entries
    return redirect_to(shopping_list_path, alert: nothing_to_record_message) if rows.empty?

    @purchase = Purchase.new(acquired_on: @today, today: @today, user: Current.user,
      lines: rows.map { |row| Purchase::Line.for(row) },
      free_text_ids: @free_text_entries.map(&:id))
  end

  def create
    @free_text_entries = checked_free_text_entries
    # そもそも行が 1 つも送られていない (フォームが空 / 壊れている)
    return redirect_to(shopping_list_path, alert: nothing_to_record_message) if line_params.empty?

    @purchase = build_purchase
    # 送られた行の一部でも消えている / チェックが外れているなら、**1 件も記録しない**。
    # 残りだけを黙って記録すると、何が記録されたのか分からなくなる
    return redirect_to(shopping_list_path, alert: STALE_MESSAGE) if stale?
    return render(:new, status: :unprocessable_content) unless @purchase.valid?

    record_purchase
  end

  private
    def set_stores
      @stores = Store.ordered
    end

    # 送られた行の数と、いま実際にチェックされている行の数が合わない
    def stale?
      @purchase.lines.size != line_params.size
    end

    def record_purchase
      result = Stock::RecordBulkPurchase.call(purchase: @purchase, user: Current.user, today: @today)

      case result.status
      when :ok
        redirect_to shopping_list_path, notice: recorded_notice(result)
      when :stale
        # フォームを開いている間に他の人が記録した。入力を捨てて一覧へ戻す
        redirect_to shopping_list_path, alert: STALE_MESSAGE
      else
        render :new, status: :unprocessable_content
      end
    end

    def recorded_notice(result)
      notice = "#{result.lot_count} 件の購入を記録しました。"
      return notice if result.free_text_count.zero?

      "#{notice} 自由入力の #{result.free_text_count} 件は在庫に記録せずリストから消しました。"
    end

    # チェック済みの行を、送られてきた順のまま組み立てる
    # (検証エラーで描き直したときに並びが変わらないように)
    def build_purchase
      entries = checked_entries.index_by { |entry| entry.id.to_s }
      lines = line_params.keys.filter_map { |id|
        entry = entries[id]
        Purchase::Line.new(record: entry, item: entry.item, attributes: line_params[id]) if entry
      }

      Purchase.new(acquired_on: header_param(:acquired_on), store_id: header_param(:store_id),
        user: Current.user, today: @today, lines: lines, free_text_ids: free_text_id_params)
    end

    # この画面に出ていた自由入力の行だけを「買った」として消す
    def free_text_id_params
      ids = purchase_params[:free_text_ids]
      return [] unless ids.is_a?(Array)

      ids.filter_map { |id|
        value = Integer(id.to_s, 10, exception: false)
        value if value&.between?(1, MAX_ID)
      }
    end

    # チェックが自由入力だけのときは、在庫に記録できないことを伝える
    def nothing_to_record_message
      @free_text_entries.present? ? FREE_TEXT_ONLY_MESSAGE : NO_CHECKED_MESSAGE
    end

    # 壊れた形のパラメータ (配列・ハッシュ) は受け取らない
    # (日付に配列が入ると Date との比較で 500 になる)
    def header_param(key)
      value = purchase_params[key]

      value if value.is_a?(String)
    end

    def purchase_params
      @purchase_params ||=
        params[:purchase].is_a?(ActionController::Parameters) ? params[:purchase] : ActionController::Parameters.new
    end

    # アーカイブ済みの品目は買い物リストに出ないので、まとめ購入の対象にもしない
    def checked_entries
      ShoppingListItem.checked.for_items.includes(:item)
        .where(item_id: Item.active.select(:id)).to_a
    end

    def checked_free_text_entries
      ShoppingListItem.checked.free_text_entries.order(:id).to_a
    end

    # purchase[lines][<行の id>][...]。壊れた形のパラメータで 500 にしない
    def line_params
      @line_params ||= begin
        lines = purchase_params[:lines]
        lines = ActionController::Parameters.new unless lines.is_a?(ActionController::Parameters)

        lines.to_unsafe_h.to_h { |id, attributes|
          [ id.to_s, attributes.is_a?(Hash) ? attributes.slice(*LINE_KEYS) : {} ]
        }
      end
    end
end
