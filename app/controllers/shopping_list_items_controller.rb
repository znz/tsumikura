class ShoppingListItemsController < ApplicationController
  # 買い物リストの永続行 (docs/spec/01-domain-model.md 判断 5)。
  #
  # 自動で並んでいる行にチェック・数量の上書き・スヌーズが来たときに、
  # find_or_initialize_by(item_id:) で**初めて**行を作る (一覧を開いただけでは作らない)。
  # 操作はすべて「この状態にする」(checked=true / false) で送る。トグルにすると、
  # 家族が同時に開いている古い画面からの操作でチェックが反転してしまう。

  include ShoppingListLoading

  # フォームから受け取るのはこれだけ。added_by_id / checked_at / snoozed_until は
  # 受け取らない (他人名義の行や、任意の時刻のチェックを作らせない)
  PERMITTED_ATTRIBUTES = %i[ item_id free_text quantity checked snoozed manual ].freeze

  # 8 バイト整数の上限。これを超える id を where に渡すと PG が範囲エラーを返して 500 になる
  MAX_ID = 2**63 - 1

  # 行が消えていた。購入で片づいたのか、誰かが掃除したのかは区別できないので両方を伝える
  # (品目 id から行を作り直したりはしない。購入直後の古い画面から再チェックできてしまう)
  GONE_MESSAGE =
    "リストが更新されています。もう一度操作してください (ほかの人が先に購入を記録したか、行が片づけられました)。".freeze
  MISSING_ITEM_MESSAGE = "その品目は見つかりませんでした。".freeze

  def create
    if entry_params[:item_id].present?
      create_for_item
    else
      create_free_text
    end
  end

  def update
    @entry = find_entry
    return if performed?

    apply_requested_state(@entry)

    if @entry.save
      respond_saved(state_notice(@entry))
    else
      render_list
    end
  end

  def destroy
    @entry = find_entry
    return if performed?

    name = @entry.display_name
    @entry.destroy
    redirect_to shopping_list_path, status: :see_other,
      notice: "「#{name}」を買い物リストから外しました。"
  end

  private
    # 品目の行は 1 品目 1 行。すでにあれば作らずにその行を操作する (二重チェックでも増えない)
    def create_for_item
      item = find_item
      return if performed?
      # 操作も手動追加の指定も無い POST は、行を作る理由がない
      # (作ってすぐ片づける行を「追加しました」と言わない)
      return head(:bad_request) unless state_requested? || manual_requested?

      @entry = ShoppingListItem.find_or_initialize_by(item_id: item.id)
      notice = create_notice(@entry, item)
      apply_requested_state(@entry)

      save_entry(item) ? respond_saved(notice) : render_list
    end

    def create_free_text
      @entry = ShoppingListItem.new(free_text: entry_params[:free_text],
        added_by: Current.user, added_manually: true)
      apply_requested_state(@entry)

      if @entry.save
        respond_saved("「#{@entry.display_name}」を買い物リストに追加しました。")
      else
        render_list
      end
    end

    # 同じ品目の行を 2 人が同時に作ると、DB の部分一意 index (RecordNotUnique) か
    # uniqueness の検証エラーになる。どちらも「相手が作った行」に同じ操作をやり直せば済むので、
    # **1 度だけ**やり直す (負けた側の操作を黙って捨てない)
    def save_entry(item)
      return true if @entry.save
      return false unless uniqueness_conflict?(@entry)

      retry_on_existing(item)
    rescue ActiveRecord::RecordNotUnique
      retry_on_existing(item)
    end

    def retry_on_existing(item)
      existing = ShoppingListItem.find_by(item_id: item.id)
      return false if existing.nil?   # 相手が作った行がもう無い。やり直さない

      @entry = existing
      apply_requested_state(@entry)
      @entry.save
    end

    # 競合したのか、入力そのものが悪いのかを分ける。
    # 入力が悪い (数量が数字でない) ときにやり直すと、エラーを握りつぶしてしまう
    def uniqueness_conflict?(entry)
      entry.new_record? && entry.errors.all? { |error| error.attribute == :item_id }
    end

    def respond_saved(notice)
      purge_if_blank(@entry)
      # JS が無いときにスクロール位置が先頭に戻らないよう、操作した行に戻す
      redirect_to shopping_list_path(anchor: row_anchor(@entry)), notice: notice
    end

    # 何の意図も残らなかった行 (チェックを外しただけ) は残さない。
    # **条件付きの DELETE** にして、読んだあとに他の人が付けたチェックごと消さないようにする
    def purge_if_blank(entry)
      ShoppingListItem.blank_for_items(@today).where(id: entry.id).delete_all
    end

    def row_anchor(entry)
      ShoppingLists::Row.dom_id(item_id: entry.item_id, record_id: entry.id)
    end

    # 検証エラーは一覧を描き直して伝える (自由入力の入力値は保つ)
    def render_list
      @new_entry = @entry if @entry.item_id.blank?
      # 競合のやり直しにも失敗した (相手の行がもう無い) ときはエラーが付いていない
      flash.now[:alert] = @entry.errors.full_messages.to_sentence.presence || GONE_MESSAGE
      load_shopping_list

      render "shopping_lists/show", status: :unprocessable_content
    end

    def find_item
      item = Item.active.find_by(id: resolved_id(entry_params[:item_id]))
      redirect_to(shopping_list_path, alert: MISSING_ITEM_MESSAGE) if item.nil?
      item
    end

    # まとめ購入や掃除で消えた行への操作。404 ではなく、やり直せることを伝えて一覧へ戻す
    def find_entry
      entry = ShoppingListItem.find_by(id: resolved_id(params[:id]))
      redirect_to(shopping_list_path, alert: GONE_MESSAGE) if entry.nil?
      entry
    end

    # 「この状態にする」を明示して受け取る (トグルにしない)。
    # 競合でやり直すときにも同じ操作を適用できるよう、1 か所にまとめる
    def apply_requested_state(entry)
      # 既存の行の「追加した人」は変えない。id で入れて関連を読み込まない (無駄なクエリを出さない)
      entry.added_by_id ||= Current.user.id

      if manual_requested?
        entry.added_manually = true
        # 手で足したのに畳まれたまま、を避ける (スヌーズは「今回は買わない」の意思表示)
        entry.snoozed_until = nil
      end

      entry.quantity = entry_params[:quantity].presence if entry_params.key?(:quantity)

      case entry_params[:checked]
      when "true"  then entry.checked_at ||= Time.current  # 二重チェックで時刻を動かさない
      when "false" then entry.checked_at = nil
      end

      case entry_params[:snoozed]
      when "true"  then entry.snoozed_until = @today + ShoppingListItem::SNOOZE_DAYS
      when "false" then entry.snoozed_until = nil
      end
    end

    def state_requested?
      %i[ checked snoozed quantity ].any? { |key| entry_params.key?(key) }
    end

    def manual_requested?
      entry_params[:manual] == "true"
    end

    def create_notice(entry, item)
      return state_notice(entry) if state_requested?

      # すでに並んでいる品目を足しても何も起きないことを伝える。
      # 「行があるか」ではなく「一覧に出ていたか」で判断する
      # (スヌーズ中の行や、数量の上書きだけが残った行は一覧に出ていない)
      if listed_before?(entry, item)
        "「#{item.name}」はすでに買い物リストにあります。"
      else
        "「#{item.name}」を買い物リストに追加しました。"
      end
    end

    def listed_before?(entry, item)
      return false if entry.snoozed?(@today)
      return true if entry.checked? || entry.added_manually?

      auto_listed?(item)
    end

    def state_notice(entry)
      name = entry.display_name

      case
      when entry_params[:checked] == "true"  then "「#{name}」をチェックしました。"
      when entry_params[:checked] == "false" then "「#{name}」のチェックを外しました。"
      when entry_params[:snoozed] == "true"
        "「#{name}」は #{ShoppingListItem::SNOOZE_DAYS} 日後まで並べません。"
      when entry_params[:snoozed] == "false" then "「#{name}」のスヌーズを解除しました。"
      when entry_params.key?(:quantity)      then "「#{name}」の数量を変えました。"
      else "買い物リストを更新しました。"
      end
    end

    # すでに要購入で自動的に並んでいるか (1 品目だけなので ItemForecaster を使う)
    def auto_listed?(item)
      status = Forecast::ItemForecaster.call(item, today: @today).status

      ShoppingLists::Row::AUTO_STATUSES.include?(status)
    end

    def entry_params
      @entry_params ||= params.expect(shopping_list_item: PERMITTED_ATTRIBUTES)
    end

    def resolved_id(value)
      return nil unless value.is_a?(String)

      id = Integer(value, 10, exception: false)
      id if id&.between?(1, MAX_ID)
    end
end
