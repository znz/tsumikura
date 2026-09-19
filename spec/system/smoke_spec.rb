require "rails_helper"

RSpec.describe "トップページ", type: :system do
  it "アクセスすると「つみくら」とキャッチコピーが表示される" do
    visit root_path

    expect(page).to have_css("h1", text: "つみくら")
    expect(page).to have_text("家族でつなぐ、暮らしのストック")
  end

  it "html 要素の lang 属性が ja になっている" do
    visit root_path

    expect(page).to have_css('html[lang="ja"]')
  end

  it "Tailwind のビルド成果物がスタイルシートとして読み込まれている" do
    visit root_path

    expect(page).to have_css('link[rel="stylesheet"][href*="tailwind"]', visible: :all)
  end
end
