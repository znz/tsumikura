module ShoppingLists
  # 画面 1 枚ぶんの買い物リスト (docs/spec/03-screens.md 画面 7)。
  # rows は表示順に並んだ Row、snoozed_rows は「今回は買わない」で畳んである行。
  # DB に触らない PORO (Merger が組み立てる)。
  class List < Data.define(:rows, :snoozed_rows)
    # 自動 (要購入) セクション
    def auto_rows
      rows.select(&:auto?)
    end

    # 手動追加セクション (手で足した品目 + 自由入力 + 判定が外れたチェック済み)
    def manual_rows
      rows.reject(&:auto?)
    end

    def checked_rows
      rows.select(&:checked?)
    end

    # まとめ購入で在庫に記録できる行 (品目つき)
    def checked_item_rows
      checked_rows.reject(&:free_text?)
    end

    # 自由入力は品目が無いので在庫には記録できない
    def checked_free_text_rows
      checked_rows.select(&:free_text?)
    end

    def checked_count
      checked_rows.size
    end

    def snoozed_count
      snoozed_rows.size
    end

    def empty?
      rows.empty?
    end
  end
end
