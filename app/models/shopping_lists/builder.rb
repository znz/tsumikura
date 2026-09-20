module ShoppingLists
  # 買い物リスト 1 画面ぶんを読み込んで組み立てる (docs/spec/01-domain-model.md 判断 5)。
  #
  # 要購入の導出は Forecast::BatchForecaster.call(Item.active) の status をそのまま使う
  # (品目一覧の ?purchase=urgent と同じ導出。SQL で書き直さない。docs/spec/02-forecast.md 14 節)。
  # 読むだけで書かないので、一覧を開いても shopping_list_items は増えない。
  # クエリ数は品目が増えても一定 (品目 1 + 集計 4 + 永続行 1)。
  module Builder
    module_function

    def call(today: Date.current)
      items = Item.active.ordered.to_a

      Merger.call(
        items: items,
        forecasts: Forecast::BatchForecaster.call(items, today: today),
        # 永続行は数が少ない (手を加えたものだけ) ので全件読む。
        # 品目は items から引き当てるので includes(:item) は要らない
        records: ShoppingListItem.all.to_a,
        today: today
      )
    end
  end
end
