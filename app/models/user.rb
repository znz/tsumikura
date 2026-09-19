class User < ApplicationRecord
  # 家族が手で入力するパスワードなので、最低限の長さだけを課す (docs/spec/05-auth.md)
  MINIMUM_PASSWORD_LENGTH = 8

  # 管理者が発行するパスワードは読み上げ・書き写しを前提にするため、
  # 紛らわしい文字 (0 1 i l o I O Q) を外した文字種から作る
  GENERATED_PASSWORD_CHARS = [
    *(("a".."z").to_a - %w[ i l o ]),
    *(("A".."Z").to_a - %w[ I O Q ]),
    *("2".."9").to_a
  ].freeze
  GENERATED_PASSWORD_GROUPS = 4
  GENERATED_PASSWORD_GROUP_SIZE = 4

  has_secure_password
  has_many :sessions, dependent: :destroy

  enum :role, { member: 0, admin: 1 }, validate: true

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :name, presence: true, length: { maximum: 50 }
  validates :email_address, presence: true, uniqueness: true
  # allow_blank は同じ validates のすべての検証に効くので、presence とは分けて書く
  validates :email_address, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :password, length: { minimum: MINIMUM_PASSWORD_LENGTH }, allow_nil: true

  validate :active_admin_must_remain

  scope :active, -> { where(deactivated_at: nil) }

  # 4 文字ごとに区切って読み間違いと打ち間違いを減らす
  def self.generate_password
    Array.new(GENERATED_PASSWORD_GROUPS) {
      SecureRandom.alphanumeric(GENERATED_PASSWORD_GROUP_SIZE, chars: GENERATED_PASSWORD_CHARS)
    }.join("-")
  end

  def deactivated?
    deactivated_at.present?
  end

  private
    # 有効な管理者が 0 人になる変更 (降格・無効化) を禁じる。
    # 無効化済みの管理者は「有効な管理者」に数えない (docs/spec/05-auth.md)
    def active_admin_must_remain
      return if admin? && !deactivated?
      return if User.admin.active.where.not(id: id).exists?
      return unless active_admin_in_database?

      errors.add(:role, :last_admin) unless admin?
      errors.add(:deactivated_at, :last_admin) if deactivated?
    end

    def active_admin_in_database?
      persisted? && User.admin.active.exists?(id: id)
    end
end
