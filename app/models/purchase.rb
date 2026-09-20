class Purchase
  # 「まとめ購入」の入力フォーム 1 回ぶん (docs/spec/03-screens.md 画面 5b)。
  # 買い物リストのチェック済み行から、店舗と購入日を共通にして複数品目の Lot を 1 度に作る。
  # 購入そのものは品目ごとの Lot なので DB のテーブルは持たない (Disposal と同じ流儀)。
  #
  # 行ごとの入力の検証は Lot がそのまま受け持つ (数量・入数 × パック数・金額・期限の規則を
  # 単品の購入と 1 か所にそろえる)。
  include ActiveModel::Model
  include ActiveModel::Attributes

  # 8 バイト整数の上限。これを超える id を where に渡すと PG が範囲エラーを返して 500 になる
  MAX_ID = 2**63 - 1

  attribute :acquired_on, :date
  attribute :store_id, :integer

  attr_reader :lines, :user, :today, :free_text_ids

  validates :acquired_on, presence: true
  validate :acquired_on_cannot_be_in_the_future
  validate :store_must_exist
  validate :lines_must_be_present
  validate :lines_must_be_valid

  # free_text_ids は「この画面に出ていた」自由入力の行。記録の成功時に一緒に消す対象を
  # フォームに出ていた行だけに限る (開いている間に他の人がチェックした行まで消さない)
  def initialize(acquired_on: nil, store_id: nil, lines: [], user: nil, free_text_ids: [],
    today: Date.current)
    super(acquired_on: acquired_on, store_id: store_id)
    @lines = lines
    @user = user
    @free_text_ids = free_text_ids
    @today = today
    sync_lines
  end

  # 共通の購入日・店舗・記録者は、検証のたびに行 (Lot) へ配り直す
  def valid?(context = nil)
    sync_lines
    super
  end

  def store
    return nil unless store_id.is_a?(Integer) && store_id.between?(1, MAX_ID)

    @store ||= Store.find_by(id: store_id)
  end

  def record_ids
    lines.map { |line| line.record.id }
  end

  private
    def sync_lines
      lines.each { |line| line.apply_header(acquired_on: acquired_on, store_id: store_id, user: user) }
    end

    # 消費イベントが必ず今日以前にあることを予測が前提にしている
    # (docs/spec/01-domain-model.md 2 節)
    def acquired_on_cannot_be_in_the_future
      return if acquired_on.blank?

      # today は 1 リクエストにつき 1 回取ったものを受け取る (画面の max と同じ基準にする)
      errors.add(:acquired_on, :future) if acquired_on > today
    end

    # フォームを開いている間に店舗が削除されると、そのままでは外部キー違反 (500) になる
    def store_must_exist
      return if store_id.blank?

      errors.add(:store_id, :invalid) if store.nil?
    end

    def lines_must_be_present
      errors.add(:base, :no_lines) if lines.empty?
    end

    # ヘッダ (購入日・店舗) が直るまでは行のエラーを出さない。
    # 購入日は全行の Lot に配るので、空のままだと全行に同じエラーが並んでしまう
    def lines_must_be_valid
      return if errors.any?

      lines.each do |line|
        errors.add(:base, :line_invalid, name: line.item.name) unless line.valid?
      end
    end
end
