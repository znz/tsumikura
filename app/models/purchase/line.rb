class Purchase
  # まとめ購入の 1 行 = 買い物リストのチェック済み行 1 件ぶんの購入入力。
  # 入力の検証は Lot に任せる (単品の購入と同じ規則を再利用する)。
  class Line
    # 行ごとに入れる値。購入日・店舗・記録者はヘッダ (Purchase) から配る
    LOT_ATTRIBUTES = %i[ initial_quantity pack_size pack_count price_yen expires_on ].freeze

    attr_reader :record, :item
    attr_accessor :lot

    # 買い物リストの行 (ShoppingLists::Row) から、希望数量を初期値にした行を作る。
    #
    # 初期値を入れるのは「入数 × パック数」と「数量」の**どちらか一方だけ**にする。
    # 両方を埋めると、数量だけ書き換えたときに入数 × パック数の積が黙って勝ってしまう
    # (Lot#apply_pack_quantity)
    def self.for(row)
      quantity = row.quantity
      pack_size = row.item.default_pack_size
      attributes =
        if pack_size.present? && pack_size.positive? && (quantity % pack_size).zero?
          { pack_size: pack_size, pack_count: quantity / pack_size }
        else
          { initial_quantity: quantity }
        end

      new(record: row.record, item: row.item, attributes: attributes)
    end

    def initialize(record:, item:, attributes: {})
      @record = record
      @item = item
      @lot = Lot.new(kind: :purchase, item: item, **lot_input(attributes))
    end

    def apply_header(acquired_on:, store_id:, user:)
      lot.acquired_on = acquired_on
      lot.store_id = store_id
      lot.user = user
    end

    def valid?
      lot.valid?
    end

    # 行だけのエラー (購入日・店舗はヘッダ側で 1 度だけ出す)
    def errors
      lot.errors.select { |error| LOT_ATTRIBUTES.include?(error.attribute) }
    end

    # Stock::RecordPurchase に渡す属性。キャッシュ列と品目・記録者は渡さない
    # (サービス側が item / user / remaining_quantity を組み立てる)
    def lot_attributes
      lot.attributes.symbolize_keys.slice(:kind, :acquired_on, :store_id, *LOT_ATTRIBUTES)
    end

    private
      def lot_input(attributes)
        attributes.symbolize_keys.slice(*LOT_ATTRIBUTES)
      end
  end
end
