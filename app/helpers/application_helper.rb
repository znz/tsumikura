module ApplicationHelper
  def user_role_label(user)
    t("enums.user.role.#{user.role}")
  end
end
