class RecordMenusController < ApplicationController
  # 下部タブの中央「＋記録」の実体 (docs/spec/03-screens.md 1 節)。
  # アクションシートは JS が要るので、メニュー (/menu) と同じくページにする
  # (JS なしで動き、system spec も rack_test で回せる)。
  def show
  end
end
