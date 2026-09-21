require "rails_helper"

RSpec.describe "トップページ", type: :system do
  it "未ログインでアクセスするとログイン画面が表示される" do
    visit root_path

    expect(page).to have_current_path(new_session_path)
    expect(page).to have_field("メールアドレス")
  end

  it "ログインするとダッシュボードが表示される" do
    user = create(:user, name: "はなこ")

    sign_in_as user

    expect(page).to have_current_path(root_path)
    expect(page).to have_css("h1", text: "つみくら")
    expect(page).to have_text("ようこそ、はなこさん。")
  end

  it "誤ったパスワードではログインできない" do
    user = create(:user)

    sign_in_as user, password: "wrong-password", wait_for_login: false

    expect(page).to have_current_path(new_session_path)
    expect(page).to have_text("メールアドレスまたはパスワードが違います。")
  end

  it "ログイン画面には「パスワードを忘れた」リンクではなく管理者への案内を出す" do
    visit new_session_path

    expect(page).to have_text("パスワードを忘れたら管理者に再設定してもらってください。")
    expect(page).to have_no_link("パスワードを忘れた")
  end

  it "html 要素の lang 属性が ja になっている" do
    visit root_path

    expect(page).to have_css('html[lang="ja"]')
  end

  it "viewport が viewport-fit=cover になっている (下部タブが safe-area を使えるように)" do
    visit root_path

    expect(page).to have_css('meta[name="viewport"][content*="viewport-fit=cover"]', visible: :all)
  end

  it "Tailwind のビルド成果物がスタイルシートとして読み込まれている" do
    visit root_path

    expect(page).to have_css('link[rel="stylesheet"][href*="tailwind"]', visible: :all)
  end
end
