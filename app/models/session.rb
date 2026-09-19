class Session < ApplicationRecord
  belongs_to :user

  # 無効化されたユーザーのセッションは復元させない (docs/spec/05-auth.md)
  scope :active, -> { joins(:user).merge(User.active) }
end
