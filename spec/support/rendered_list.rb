# 「一覧に出る / 出ない」の検証を、一覧要素の中だけに絞るためのヘルパー。
#
# response.body 全体を見ると、flash の文言 (「〜をアーカイブしました」) や
# 絞り込みセレクトの option にも名前が出るため、検証が偽陽性・偽陰性になる。
# 一覧の ul には aria-label を付けてあるので、そこだけを見る。
module RenderedList
  def rendered_list(aria_label)
    response.parsed_body.css(%(ul[aria-label="#{aria_label}"])).text
  end
end

RSpec.configure do |config|
  config.include RenderedList, type: :request
end
