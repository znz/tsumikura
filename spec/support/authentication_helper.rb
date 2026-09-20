# ログインのヘルパー。cookie を直接作らず、実際にログイン画面と同じ経路を通す
# (無効化ユーザーの拒否など SessionsController の振る舞いをテストから迂回させないため)。
module AuthenticationHelper
  # spec/factories/users.rb の既定パスワード
  DEFAULT_PASSWORD = "password".freeze

  # request spec 用
  def sign_in(user, password: DEFAULT_PASSWORD)
    post session_path, params: { email_address: user.email_address, password: password }
  end

  def sign_out
    delete session_path
  end
end

# system spec 用
module SystemAuthenticationHelper
  def sign_in_as(user, password: AuthenticationHelper::DEFAULT_PASSWORD)
    visit new_session_path
    fill_in "メールアドレス", with: user.email_address
    fill_in "パスワード", with: password
    # 実ブラウザ (js: true) ではログイン画面に「パスキーでログイン」ボタンも出る。
    # Capybara の既定は部分一致なので、exact: true でパスワードの送信ボタンだけを押す
    click_button "ログイン", exact: true
  end
end

RSpec.configure do |config|
  config.include AuthenticationHelper, type: :request
  config.include SystemAuthenticationHelper, type: :system
end
