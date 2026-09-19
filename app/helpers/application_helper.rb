module ApplicationHelper
  # フォームとボタンの見た目。タップ領域は 44px 以上 (min-h-11) を守る (docs/spec/03-screens.md)
  def field_classes(extra = nil)
    class_names("mt-2 block min-h-11 w-full rounded-lg border border-slate-300 px-3 py-2 shadow-sm focus:outline-blue-600", extra)
  end

  def label_classes(extra = nil)
    class_names("block text-sm font-medium text-slate-700", extra)
  end

  def hint_classes(extra = nil)
    class_names("mt-1 text-sm text-slate-500", extra)
  end

  def primary_button_classes(extra = nil)
    class_names("min-h-11 w-full cursor-pointer rounded-lg bg-blue-600 px-4 py-3 font-medium text-white hover:bg-blue-500", extra)
  end

  def secondary_button_classes(extra = nil)
    class_names("flex min-h-11 items-center justify-center rounded-lg border border-slate-300 px-3 text-sm text-slate-700 hover:bg-slate-50", extra)
  end

  def danger_button_classes(extra = nil)
    class_names("min-h-11 w-full cursor-pointer rounded-lg border border-red-300 px-4 py-3 text-sm font-medium text-red-700 hover:bg-red-50", extra)
  end

  # 各一覧の右上にある「〜を追加」リンク (主ボタンの小型版)
  def add_link_classes(extra = nil)
    class_names("flex min-h-11 items-center rounded-lg bg-blue-600 px-4 font-medium text-white hover:bg-blue-500", extra)
  end

  # 下部タブの「品目」は、一覧だけでなく詳細やフォームでもハイライトする
  def items_tab_current?
    controller_path == "items" || controller_path.start_with?("items/")
  end

  def user_role_label(user)
    t("enums.user.role.#{user.role}")
  end

  def item_estimation_mode_label(item)
    t("enums.item.estimation_mode.#{item.estimation_mode}")
  end
end
