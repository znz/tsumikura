namespace :tsumikura do
  desc "管理者を作る (ADMIN_EMAIL は必須。ADMIN_NAME / ADMIN_PASSWORD / ADMIN_RESET_PASSWORD は任意)"
  task create_admin: :environment do
    email = ENV["ADMIN_EMAIL"].to_s.strip
    if email.blank?
      abort "ADMIN_EMAIL を指定してください " \
            "(例: bin/rails tsumikura:create_admin ADMIN_EMAIL=admin@example.com ADMIN_NAME=かんりしゃ)"
    end

    name = ENV["ADMIN_NAME"].presence || "かんりしゃ"
    given_password = ENV["ADMIN_PASSWORD"].presence

    if (user = User.find_by(email_address: email))
      # 冪等にする: 重複して作らず role を admin に揃える (docs/spec/05-auth.md 3 節)。
      # パスワードは明示されたときだけ変える (ADMIN_PASSWORD / ADMIN_RESET_PASSWORD=1)
      new_password = given_password || (ENV["ADMIN_RESET_PASSWORD"].present? ? User.generate_password : nil)

      user.role = :admin
      user.password = new_password if new_password
      abort user.errors.full_messages.to_sentence unless user.save

      # パスワードを変えたら、そのユーザーのログイン中セッションはすべて失効させる
      user.sessions.destroy_all if new_password

      puts "#{user.email_address} は既に登録されています。role を admin にしました。"
      if new_password
        puts "パスワードを再設定し、ログイン中のデバイスをすべてログアウトしました。"
        puts "パスワード: #{new_password}" unless given_password
      else
        puts "パスワードは変更していません (再設定するなら ADMIN_RESET_PASSWORD=1)。"
      end
      if user.deactivated?
        puts "このユーザーは無効化されています。/admin/users から再有効化するか、" \
             "または別の ADMIN_EMAIL で新しい管理者を作成してください。"
      end
    else
      password = given_password || User.generate_password
      user = User.new(email_address: email, name: name, role: :admin, password: password)
      abort user.errors.full_messages.to_sentence unless user.save

      puts "管理者 #{user.email_address} (#{user.name}) を作成しました。"
      unless given_password
        puts "パスワード: #{password}"
        puts "この表示は 1 度だけです。控えたうえで、ログイン後にアカウント設定から変更してください。"
      end
    end
  end
end
