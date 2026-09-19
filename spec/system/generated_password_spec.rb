require "rails_helper"

# 生成パスワードは「リダイレクトせず POST のレスポンスに直接描画する」方式なので、
# フォームの data-turbo=false が外れると Turbo がレスポンスを捨てて何も表示されなくなる。
# rack_test では JS が動かず気づけないため、実ブラウザで担保する
# (Chrome の無い環境では spec/support/capybara.rb が skip する)。
RSpec.describe "生成パスワードの表示", type: :system, js: true do
  it "ユーザーを追加すると初期パスワードが画面に表示される" do
    sign_in_as create(:user, :admin)

    visit new_admin_user_path
    fill_in "表示名", with: "おとうさん"
    fill_in "メールアドレス", with: "father@example.com"
    click_button "追加して初期パスワードを表示"

    expect(page).to have_css("#generated-password", text: /\S/)
    expect(page).to have_text("この画面でしか表示されません")
  end

  it "パスワードを再設定すると新しいパスワードが画面に表示される" do
    member = create(:user)
    sign_in_as create(:user, :admin)

    visit new_admin_user_password_reset_path(member)
    click_button "新しいパスワードを発行"

    expect(page).to have_css("#generated-password", text: /\S/)
    expect(page).to have_text("この画面でしか表示されません")
  end
end
