# どの環境でも ENV なしで実行でき、何度実行しても同じ結果になる (冪等) ようにする。
# CI が `db:seed:replant` を流すため、ここで例外を出さないこと (docs/ops/development.md 8 節)。
#
# 最初の管理者は seeds ではなく rake タスクで作る (docs/spec/05-auth.md 3 節):
#   bin/rails tsumikura:create_admin ADMIN_EMAIL=admin@example.com ADMIN_NAME=かんりしゃ

# 開発環境だけ、すぐログインを試せる管理者を用意する。
# 本番・test では作らない (弱いパスワードの管理者を本番に作らないため)。
if Rails.env.development?
  User.find_or_create_by!(email_address: "admin@example.com") do |user|
    user.name = "かんりしゃ"
    user.role = :admin
    user.password = "tsumikura-dev"
  end

  puts "development 用の管理者: admin@example.com / tsumikura-dev"
end
