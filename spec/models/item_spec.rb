require "rails_helper"

RSpec.describe Item, type: :model do
  describe "バリデーション" do
    it "name は必須" do
      item = build(:item, name: "")

      expect(item).not_to be_valid
      expect(item.errors[:name]).to be_present
    end

    it "unit は必須" do
      item = build(:item, unit: "")

      expect(item).not_to be_valid
      expect(item.errors[:unit]).to be_present
    end

    it "unit の既定値は 個" do
      expect(described_class.new.unit).to eq "個"
    end

    it "unit は自由入力できる (候補以外も保存できる)" do
      item = build(:item, unit: "ダース")

      expect(item).to be_valid
    end

    it "name は 50 文字まで" do
      expect(build(:item, name: "あ" * 50)).to be_valid
      expect(build(:item, name: "あ" * 51)).not_to be_valid
    end

    it "name_reading は 100 文字まで" do
      expect(build(:item, name_reading: "あ" * 100)).to be_valid
      expect(build(:item, name_reading: "あ" * 101)).not_to be_valid
    end

    it "unit は 20 文字まで" do
      expect(build(:item, unit: "あ" * 20)).to be_valid
      expect(build(:item, unit: "あ" * 21)).not_to be_valid
    end

    it "入数の既定値は 1 以上でなければ保存できない" do
      expect(build(:item, default_pack_size: 0)).not_to be_valid
      expect(build(:item, default_pack_size: 1)).to be_valid
      expect(build(:item, default_pack_size: nil)).to be_valid
    end

    it "最低在庫数は 0 以上でなければ保存できない" do
      expect(build(:item, minimum_quantity: -1)).not_to be_valid
      expect(build(:item, minimum_quantity: 0)).to be_valid
      expect(build(:item, minimum_quantity: nil)).to be_valid
    end

    it "manual_interval_days は 1 以上でなければ保存できない (0 や負ではペースを出せない)" do
      expect(build(:item, :manual_estimation, manual_interval_days: 0)).not_to be_valid
      expect(build(:item, :manual_estimation, manual_interval_days: -1)).not_to be_valid
      expect(build(:item, :manual_estimation, manual_interval_days: 1)).to be_valid
    end

    # 「手動」を選んで間隔を空のままにすると、予測が永久に unknown になり auto より悪い状態に
    # 黙って落ちる。UI で気づけるよう必須にする (docs/spec/02-forecast.md 8 節)
    it "estimation_mode が manual なら manual_interval_days は必須" do
      item = build(:item, estimation_mode: :manual, manual_interval_days: nil)

      expect(item).not_to be_valid
      expect(item.errors[:manual_interval_days]).to be_present
    end

    it "estimation_mode が auto / none なら manual_interval_days は空でよい" do
      expect(build(:item, estimation_mode: :auto, manual_interval_days: nil)).to be_valid
      expect(build(:item, estimation_mode: :none, manual_interval_days: nil)).to be_valid
    end

    it "auto でも manual_interval_days が残っているのは許す (手動に戻したときに使える)" do
      expect(build(:item, estimation_mode: :auto, manual_interval_days: 30)).to be_valid
    end

    # enum は validate: true で入れているので、未知の値は例外ではなく検証エラーになる
    it "estimation_mode は auto / manual / none のいずれか" do
      item = build(:item)
      item.estimation_mode = "interval"

      expect(item).not_to be_valid
      expect(item.errors[:estimation_mode]).to be_present
    end

    it "購入推奨の日数は、そろそろ購入の日数より大きくできない" do
      item = build(:item, soon_threshold_days: 10, urgent_threshold_days: 11)

      expect(item).not_to be_valid
      expect(item.errors[:urgent_threshold_days]).to be_present
    end

    it "購入推奨の日数とそろそろ購入の日数が同じなら保存できる" do
      expect(build(:item, soon_threshold_days: 10, urgent_threshold_days: 10)).to be_valid
    end

    it "片方だけ上書きしたときは既定値と比べる" do
      # 既定は soon 21 / urgent 7
      expect(build(:item, urgent_threshold_days: 22)).not_to be_valid
      expect(build(:item, urgent_threshold_days: 21)).to be_valid
      expect(build(:item, soon_threshold_days: 6)).not_to be_valid
      expect(build(:item, soon_threshold_days: 7)).to be_valid
    end

    # そろそろ購入だけを上書きしたときは、空欄の「購入推奨の日数」にエラーが付く。
    # 何と比べて駄目なのかが分かるよう、両方の実効値を文面に入れる
    it "閾値のエラーには両方の実効値が入る" do
      item = build(:item, soon_threshold_days: 6)
      item.validate

      message = item.errors.full_messages_for(:urgent_threshold_days).first
      expect(message).to include "7 日"
      expect(message).to include "6 日"
    end

    it "閾値と期限警告日数は 0 以上でなければ保存できない" do
      expect(build(:item, soon_threshold_days: -1)).not_to be_valid
      expect(build(:item, urgent_threshold_days: -1)).not_to be_valid
      expect(build(:item, expiry_warning_days: -1)).not_to be_valid
      expect(build(:item, expiry_warning_days: 0)).to be_valid
    end

    describe "整数の上限" do
      # 上限が無いと 4 バイト整数をはみ出した値が書き込み時に ActiveModel::RangeError になり、
      # 検証エラー (422) ではなく 500 になる
      it "数量系は MAX_QUANTITY まで" do
        expect(build(:item, default_pack_size: described_class::MAX_QUANTITY)).to be_valid
        expect(build(:item, default_pack_size: described_class::MAX_QUANTITY + 1)).not_to be_valid
        expect(build(:item, minimum_quantity: described_class::MAX_QUANTITY + 1)).not_to be_valid
      end

      it "日数系は MAX_DAYS まで" do
        expect(build(:item, :manual_estimation, manual_interval_days: described_class::MAX_DAYS)).to be_valid
        expect(build(:item, :manual_estimation, manual_interval_days: described_class::MAX_DAYS + 1)).not_to be_valid
        expect(build(:item, expiry_warning_days: described_class::MAX_DAYS + 1)).not_to be_valid
        expect(build(:item, soon_threshold_days: described_class::MAX_DAYS + 1)).not_to be_valid
      end

      it "4 バイト整数をはみ出す値でも例外にならず検証エラーになる" do
        item = build(:item, default_pack_size: 99_999_999_999)

        expect { item.valid? }.not_to raise_error
        expect(item).not_to be_valid
      end
    end

    describe "削除済みのマスタを指す id" do
      # 家族 A がフォームを開いている間に B がカテゴリを削除した場合。
      # そのまま保存すると外部キー違反 (500) になるので、検証で捕まえる
      it "削除済みのカテゴリ id では保存できない" do
        category = create(:category)
        category_id = category.id
        category.destroy

        item = build(:item, category_id: category_id)

        expect(item).not_to be_valid
        expect(item.errors[:category]).to be_present
      end

      it "削除済みの保管場所 id では保存できない" do
        storage_location = create(:storage_location)
        storage_location_id = storage_location.id
        storage_location.destroy

        item = build(:item, storage_location_id: storage_location_id)

        expect(item).not_to be_valid
        expect(item.errors[:storage_location]).to be_present
      end

      # id 0 は query_attribute (category_id?) が false を返すので、present? で判定する
      it "id が 0 でも保存できない" do
        expect(build(:item, category_id: 0)).not_to be_valid
        expect(build(:item, storage_location_id: 0)).not_to be_valid
      end

      it "id が空なら検証しない" do
        expect(build(:item, category_id: nil, storage_location_id: nil)).to be_valid
      end
    end
  end

  describe "正規化" do
    it "name と unit は前後の空白を落とす" do
      item = create(:item, name: "  トイレットペーパー  ", unit: " ロール ")

      expect(item.name).to eq "トイレットペーパー"
      expect(item.unit).to eq "ロール"
    end

    it "全角スペースも落とす (String#strip は落とさない)" do
      item = create(:item, name: "　トイレットペーパー　")

      expect(item.name).to eq "トイレットペーパー"
    end

    it "よみも前後の空白を落とす" do
      item = create(:item, name_reading: "　といれっと　")

      expect(item.name_reading).to eq "といれっと"
    end

    it "よみが空白だけなら nil になる" do
      expect(create(:item, name_reading: "  ").name_reading).to be_nil
      expect(create(:item, name_reading: "　").name_reading).to be_nil
      expect(create(:item, name_reading: "").name_reading).to be_nil
    end

    it "よみはカタカナで入力してもひらがなで保存される" do
      item = create(:item, name_reading: "トイレットペーパー")

      expect(item.name_reading).to eq "といれっとぺーぱー"
    end
  end

  describe "既定値" do
    it "作成すると current_quantity は 0" do
      item = create(:item)

      expect(item.reload.current_quantity).to eq 0
    end

    it "作成直後はキャッシュ列が空で、アーカイブもされていない" do
      item = create(:item)

      expect(item.tracking_started_on).to be_nil
      expect(item.last_consumed_on).to be_nil
      expect(item.archived_at).to be_nil
    end

    it "作成すると estimation_mode は auto" do
      expect(create(:item).estimation_mode).to eq "auto"
    end
  end

  describe "DB の制約" do
    it "在庫数を負にする UPDATE は check 制約で弾かれる (キャッシュ再計算の最後の守り)" do
      item = create(:item)

      expect {
        # 例外でトランザクションが壊れないよう SAVEPOINT の中で試す
        described_class.transaction(requires_new: true) { item.update_column(:current_quantity, -1) }
      }.to raise_error(ActiveRecord::StatementInvalid)

      expect(item.reload.current_quantity).to eq 0
    end
  end

  describe "マスタとの関連" do
    it "カテゴリと保管場所は未設定でもよい" do
      expect(build(:item, category: nil, storage_location: nil)).to be_valid
    end

    it "カテゴリを削除しても品目は残り、category だけが外れる (nullify)" do
      category = create(:category)
      item = create(:item, category: category)

      expect { category.destroy }.not_to change { described_class.count }
      expect(item.reload.category_id).to be_nil
    end

    it "保管場所を削除しても品目は残り、storage_location だけが外れる (nullify)" do
      storage_location = create(:storage_location)
      item = create(:item, storage_location: storage_location)

      expect { storage_location.destroy }.not_to change { described_class.count }
      expect(item.reload.storage_location_id).to be_nil
    end

    # dependent: :nullify は destroy でしか働かない。DB 側の on_delete: :nullify が
    # 効いていることを、コールバックを通らない delete で確かめる
    it "コールバックを通らない delete でも DB 側で category_id が nil になる" do
      category = create(:category)
      item = create(:item, category: category)

      category.delete

      expect(item.reload.category_id).to be_nil
      expect(described_class.exists?(item.id)).to be true
    end

    it "コールバックを通らない delete でも DB 側で storage_location_id が nil になる" do
      storage_location = create(:storage_location)
      item = create(:item, storage_location: storage_location)

      storage_location.delete

      expect(item.reload.storage_location_id).to be_nil
      expect(described_class.exists?(item.id)).to be true
    end

    it "カテゴリを削除しても、別のカテゴリの品目は影響を受けない" do
      deleted = create(:category)
      kept = create(:category)
      create(:item, category: deleted)
      item = create(:item, category: kept)

      deleted.destroy

      expect(item.reload.category_id).to eq kept.id
    end
  end

  describe "アーカイブ" do
    it ".active は archived_at が nil のものだけを返す" do
      active = create(:item)
      archived = create(:item, :archived)

      expect(described_class.active).to include(active)
      expect(described_class.active).not_to include(archived)
    end

    it ".archived は archived_at があるものだけを返す" do
      active = create(:item)
      archived = create(:item, :archived)

      expect(described_class.archived).to contain_exactly(archived)
      expect(described_class.archived).not_to include(active)
    end

    it "#archive! は archived_at を打ち、レコードは消さない" do
      item = create(:item)

      expect { item.archive! }.not_to change { described_class.count }
      expect(item.reload).to be_archived
    end

    it "#restore! は archived_at を戻す" do
      item = create(:item, :archived)

      item.restore!

      expect(item.reload).not_to be_archived
    end

    it "#archive! はアーカイブ済みの品目のアーカイブ日時を上書きしない" do
      item = create(:item, archived_at: 3.days.ago)

      expect { item.archive! }.not_to change { item.reload.archived_at }
    end

    # 既定の閾値を変えたあとなど、保存済みの品目が invalid になることがある。
    # そのときアーカイブも復元もできなくなる (RecordInvalid で 500) のは困る
    it "バリデーションを通らない品目でもアーカイブ・復元できる" do
      item = create(:item)
      item.update_column(:name, "")
      item.reload

      expect(item).not_to be_valid
      expect { item.archive! }.not_to raise_error
      expect(item.reload).to be_archived
      expect { item.restore! }.not_to raise_error
      expect(item.reload).not_to be_archived
    end
  end

  describe ".ordered" do
    # 漢字の名前をコードポイント順に並べると五十音順にならないので、よみがあれば優先する
    it "よみがあればよみ順、無ければ名前順に並ぶ" do
      ringo = create(:item, name: "林檎", name_reading: "りんご")
      ichigo = create(:item, name: "苺", name_reading: "いちご")

      expect(described_class.ordered.to_a).to eq [ ichigo, ringo ]
    end
  end

  describe ".search" do
    it "名前の部分一致で絞り込む" do
      hit = create(:item, name: "トイレットペーパー")
      miss = create(:item, name: "ティッシュ")

      expect(described_class.search("トイレット")).to contain_exactly(hit)
      expect(described_class.search("トイレット")).not_to include(miss)
    end

    it "よみの部分一致でも絞り込む" do
      hit = create(:item, name: "食器用洗剤", name_reading: "しょっきようせんざい")
      miss = create(:item, name: "洗剤", name_reading: nil)

      expect(described_class.search("せんざい")).to contain_exactly(hit)
      expect(described_class.search("せんざい")).not_to include(miss)
    end

    it "検索語をカタカナで入れてもひらがなのよみに当たる" do
      hit = create(:item, name: "TP", name_reading: "といれっとぺーぱー")
      miss = create(:item, name: "ティッシュ")

      expect(described_class.search("トイレ")).to contain_exactly(hit)
      expect(described_class.search("トイレ")).not_to include(miss)
    end

    it "英字は大文字小文字を無視して当たる" do
      hit = create(:item, name: "AA電池")
      miss = create(:item, name: "単 3 電池")

      expect(described_class.search("aa")).to contain_exactly(hit)
      expect(described_class.search("aa")).not_to include(miss)
    end

    it "検索語が空なら絞り込まない" do
      create(:item)
      create(:item)

      expect(described_class.search("").count).to eq 2
      expect(described_class.search(nil).count).to eq 2
      expect(described_class.search("  ").count).to eq 2
      expect(described_class.search("　").count).to eq 2
    end

    it "% はワイルドカードではなくただの文字として扱う" do
      hit = create(:item, name: "100%ジュース")
      miss = create(:item, name: "100ジュース")

      expect(described_class.search("100%")).to contain_exactly(hit)
      expect(described_class.search("100%")).not_to include(miss)
    end

    it "_ はワイルドカードではなくただの文字として扱う" do
      hit = create(:item, name: "A_B 乾電池")
      miss = create(:item, name: "AXB 乾電池")

      expect(described_class.search("A_B")).to contain_exactly(hit)
      expect(described_class.search("A_B")).not_to include(miss)
    end

    it "バックスラッシュを含む検索語でもエラーにならない" do
      hit = create(:item, name: 'C:\\ドライブ用')
      create(:item, name: "Cドライブ用")

      expect(described_class.search('C:\\')).to contain_exactly(hit)
    end
  end

  describe "既定値との合成" do
    it "閾値が未設定なら config/tsumikura.yml の既定値を返す" do
      item = build(:item, soon_threshold_days: nil, urgent_threshold_days: nil, expiry_warning_days: nil)

      expect(item.effective_soon_threshold_days).to eq 21
      expect(item.effective_urgent_threshold_days).to eq 7
      expect(item.effective_expiry_warning_days).to eq 30
    end

    it "閾値が設定されていればその値を返す" do
      item = build(:item, soon_threshold_days: 30, urgent_threshold_days: 3, expiry_warning_days: 14)

      expect(item.effective_soon_threshold_days).to eq 30
      expect(item.effective_urgent_threshold_days).to eq 3
      expect(item.effective_expiry_warning_days).to eq 14
    end
  end
end
