class Disposal
  # 「廃棄」の入力フォーム 1 回ぶん (docs/spec/03-screens.md 1 節)。
  # 廃棄そのものは kind: disposal の stock_movement なので DB のテーブルは持たない。
  # 数量がロットをまたぐと movement は複数行になるので、作られた行は movements に入れる。
  #
  # 廃棄は消費に数えない (docs/spec/02-forecast.md 3 節)。期限切れ廃棄は「使った」ではなく、
  # 含めるとペースが過大になって買いすぎを招く。
  include ActiveModel::Model
  include ActiveModel::Attributes

  # 整数の上限。無いと 4 バイト整数をはみ出した入力が RangeError になり 422 ではなく 500 になる
  MAX_QUANTITY = Item::MAX_QUANTITY

  attribute :quantity, :integer
  attribute :occurred_on, :date
  # 引き当て先のロット。主キーは UUID なので文字列で受け取る (未指定なら 期限切れ → FEFO の順)
  attribute :lot_id, :string
  attribute :disposal_reason, :string  # expired / damaged / lost / other
  attribute :note, :string

  # 品目・記録者は URL とログイン中のユーザーで決まるのでフォームからは受け取らない
  attr_accessor :item, :user
  # 作られた在庫の記録 (ロットをまたぐと複数行)
  attr_accessor :movements

  # presence と numericality は **別々の validates** にする。1 つにまとめると
  # allow_nil が presence にも掛かり、数量が空のまま検証を通ってしまう
  # (引き当てで nil を数えて 500 になる)。
  # 数量の検査は quantity_before_type_cast (下で定義) を見るので、"1.5" や "2abc" が
  # 黙って 1 / 2 として記録されることはない。
  # allow_nil は「空欄のときに数値のエラーを presence と二重に出さない」ため
  validates :quantity, presence: true
  validates :quantity,
    numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_QUANTITY },
    allow_nil: true
  # id は UUID の形 (8-4-4-4-12) だけを受け付ける。ほかの形は参照先を引けないので検証で弾く
  validates :lot_id, format: { with: Base58Uuid::FORMAT, message: :invalid }, allow_blank: true
  validates :occurred_on, presence: true
  # 理由は必ず選ばせる (「なんとなく減った」を廃棄で片づけさせない)。
  # 候補は StockMovement の enum と 1 か所にそろえる
  validates :disposal_reason, inclusion: { in: ->(_record) { Disposal.reasons } }

  validate :occurred_on_cannot_be_in_the_future
  validate :lot_must_belong_to_item

  def self.reasons
    StockMovement.disposal_reasons.keys
  end

  # ActiveModel::Attributes は *_before_type_cast を作らないので自分で用意する。
  # 無いと numericality がキャスト後の値を見てしまい、"1.5" が 1、"2abc" が 2 として
  # 黙って記録される (ActiveRecord は自動で持っているので、この違いを埋める)
  def quantity_before_type_cast
    @attributes["quantity"].value_before_type_cast
  end

  # 参照先を引ける id か
  def lot_id_resolvable?
    Base58Uuid.uuid?(lot_id)
  end

  private
    # 消費イベントが必ず今日以前にあることを予測が前提にしている
    # (docs/spec/01-domain-model.md 2 節 / docs/spec/02-forecast.md)
    def occurred_on_cannot_be_in_the_future
      return if occurred_on.blank?

      errors.add(:occurred_on, :future) if occurred_on > Date.current
    end

    # 他の品目のロットは捨てられない (フォームの改ざん・古い画面からの保存)
    def lot_must_belong_to_item
      return if lot_id.blank? || errors[:lot_id].any?
      return errors.add(:lot_id, :invalid) unless lot_id_resolvable?

      errors.add(:lot_id, :invalid) unless item&.lots&.exists?(id: lot_id)
    end
end
