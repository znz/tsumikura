# DB も Rails も要らない (UUID と文字列だけを扱う純粋な関数)。
# 予測のロジック (spec/models/forecast/) と同じく spec_helper だけで回す
require "spec_helper"
require "securerandom"
require_relative "../../lib/base58_uuid"

RSpec.describe Base58Uuid do
  # 22 文字で 2**128 - 1 まで表せる (58**22 > 2**128)
  ZERO = "00000000-0000-0000-0000-000000000000".freeze
  MAX  = "ffffffff-ffff-ffff-ffff-ffffffffffff".freeze
  # PostgreSQL 18 の uuidv7() が返す形 (先頭 48 ビットがミリ秒のタイムスタンプ、7 版)
  V7   = "0199bb1c-4b0f-7c9a-8b3d-2f1e0a9c7d65".freeze

  describe ".encode" do
    it "常に 22 文字を返す" do
      expect(described_class.encode(V7).length).to eq 22
    end

    it "最小値は先頭ゼロ (アルファベットの 1) で埋める" do
      expect(described_class.encode(ZERO)).to eq "1" * 22
    end

    # 往復だけだと、エンコードとデコードが同じ向きに壊れても気づけない。
    # 手計算した固定値 (golden) で桁の並びそのものを止める
    it "固定値 (golden)" do
      expect(described_class.encode(MAX)).to eq "YcVfxkQb6JRzqk5kF2tNLv"
      expect(described_class.encode(V7)).to eq "1CTrYDDUTfb1HrfmuqXGzp"
      expect(described_class.encode("01a0c29b-28c1-7803-af0e-0a9beb8926dd"))
        .to eq "1CfG6SkU82D4ezSruXTDP2"
    end

    it "先頭が 0 の UUID でも 22 文字のまま" do
      encoded = described_class.encode("00000000-0000-0000-0000-000000000001")
      expect(encoded).to eq "1" * 21 + "2"
    end

    it "ハイフンなしでも受け付ける" do
      expect(described_class.encode(V7.delete("-"))).to eq described_class.encode(V7)
    end

    # DB から読んだ値を URL にするだけなので、大文字小文字は問わない
    it "大文字の UUID でも同じ結果" do
      expect(described_class.encode(V7.upcase)).to eq described_class.encode(V7)
    end

    # delete("-") はハイフンの位置を見ないので、形を先に検査していないと
    # 「32 桁の 16 進になりさえすればよい」ことになってしまう
    it "ハイフンの位置が正規形でなければ ArgumentError" do
      expect { described_class.encode("0-199bb1c4b0f7c9a8b3d2f1e0a9c7d65") }.to raise_error(ArgumentError)
      expect { described_class.encode("0199bb1c4b0f-7c9a-8b3d-2f1e0a9c7d65") }.to raise_error(ArgumentError)
      expect { described_class.encode("0199bb1c-4b0f-7c9a-8b3d2f1e-0a9c7d65") }.to raise_error(ArgumentError)
      expect { described_class.encode("-#{V7.delete('-')}") }.to raise_error(ArgumentError)
      expect { described_class.encode("#{V7}-") }.to raise_error(ArgumentError)
    end

    it "Base58 のアルファベット以外は出てこない" do
      100.times do
        encoded = described_class.encode(SecureRandom.uuid)
        expect(encoded).to match(/\A[#{described_class::ALPHABET}]{22}\z/)
      end
    end

    it "長さが違う値は ArgumentError" do
      expect { described_class.encode("0199bb1c-4b0f-7c9a-8b3d-2f1e0a9c7d6") }.to raise_error(ArgumentError)
      expect { described_class.encode("") }.to raise_error(ArgumentError)
    end

    it "16 進でない文字は ArgumentError" do
      expect { described_class.encode("0199bb1c-4b0f-7c9a-8b3d-2f1e0a9c7dzz") }.to raise_error(ArgumentError)
    end

    # Integer(hex, 16) はアンダースコアや "0x" や前後の空白を通してしまうので、
    # 先に正規表現で弾いていることを固定する
    it "アンダースコア・0x 接頭辞・空白は ArgumentError" do
      expect { described_class.encode("0199bb1c4b0f7c9a8b3d2f1e0a9c7d6_") }.to raise_error(ArgumentError)
      expect { described_class.encode("0x99bb1c4b0f7c9a8b3d2f1e0a9c7d65a") }.to raise_error(ArgumentError)
      expect { described_class.encode(" #{V7}") }.to raise_error(ArgumentError)
      expect { described_class.encode("#{V7}\n") }.to raise_error(ArgumentError)
    end

    it "String でない値は ArgumentError" do
      expect { described_class.encode(nil) }.to raise_error(ArgumentError)
      expect { described_class.encode(123) }.to raise_error(ArgumentError)
      expect { described_class.encode([ V7 ]) }.to raise_error(ArgumentError)
    end
  end

  describe ".decode" do
    it "ハイフンつきの正規形 (小文字) で返す" do
      expect(described_class.decode(described_class.encode(V7))).to eq V7
      expect(described_class.decode(described_class.encode(ZERO))).to eq ZERO
    end

    it "22 文字以外は ArgumentError" do
      expect { described_class.decode("1" * 21) }.to raise_error(ArgumentError)
      expect { described_class.decode("1" * 23) }.to raise_error(ArgumentError)
      expect { described_class.decode("") }.to raise_error(ArgumentError)
    end

    # 生の UUID は 36 文字なので、URL に入れてもここで落ちる
    it "生の UUID は ArgumentError" do
      expect { described_class.decode(V7) }.to raise_error(ArgumentError)
      expect { described_class.decode(V7.delete("-")) }.to raise_error(ArgumentError)
    end

    it "Base58 にない文字 (0 O I l) は ArgumentError" do
      %w[ 0 O I l ].each do |char|
        expect { described_class.decode("1" * 21 + char) }.to raise_error(ArgumentError)
      end
      expect { described_class.decode("1" * 21 + "+") }.to raise_error(ArgumentError)
    end

    # 58**22 は 2**128 より大きいので、22 文字でも 128 ビットに収まらない値が作れる
    it "128 ビットを超える 22 文字は ArgumentError" do
      overflow = described_class::ALPHABET[-1] * 22
      expect { described_class.decode(overflow) }.to raise_error(ArgumentError)
    end

    # 境界のすぐ外側。MAX を 1 つ超えた (= 2**128) 表現を名指しで弾く
    it "最大値のすぐ上 (2**128) は ArgumentError" do
      expect { described_class.decode("YcVfxkQb6JRzqk5kF2tNLw") }.to raise_error(ArgumentError, /128/)
    end

    it "固定値 (golden)" do
      expect(described_class.decode("1CfG6SkU82D4ezSruXTDP2")).to eq "01a0c29b-28c1-7803-af0e-0a9beb8926dd"
      expect(described_class.decode("YcVfxkQb6JRzqk5kF2tNLv")).to eq MAX
      expect(described_class.decode("1" * 22)).to eq ZERO
    end

    it "128 ビットちょうど (最大値) は通る" do
      expect(described_class.decode(described_class.encode(MAX))).to eq MAX
    end

    it "String でない値は ArgumentError" do
      expect { described_class.decode(nil) }.to raise_error(ArgumentError)
      expect { described_class.decode(123) }.to raise_error(ArgumentError)
      expect { described_class.decode([ "1" * 22 ]) }.to raise_error(ArgumentError)
    end
  end

  # ApplicationRecord#to_param の入口 (app/models/concerns/base58_param.rb)。
  # migration のバージョン番号を変えずに中身だけ書き換えたので、bigint のままの DB に
  # このコードを当てても db:migrate / db:prepare は「未適用なし」で成功してしまう。
  # そのまま動くと全画面が 500 になるので、原因が分かる例外にしておく
  describe ".encode_primary_key" do
    it "UUID なら encode と同じ" do
      expect(described_class.encode_primary_key(V7)).to eq described_class.encode(V7)
    end

    it "整数の id (UUID 化前の DB) は NotUuidPrimaryKey" do
      expect { described_class.encode_primary_key(1) }
        .to raise_error(described_class::NotUuidPrimaryKey, /主キーが UUID ではありません/)
    end

    it "メッセージに id と対処 (DB の作り直し) が入る" do
      described_class.encode_primary_key(42)
    rescue described_class::NotUuidPrimaryKey => error
      expect(error.message).to include "42"
      expect(error.message).to include "DB を作り直してください"
      expect(error.message).to include "deployment.md"
    end

    it "UUID でない文字列も NotUuidPrimaryKey" do
      expect { described_class.encode_primary_key("1") }
        .to raise_error(described_class::NotUuidPrimaryKey)
      expect { described_class.encode_primary_key(described_class.encode(V7)) }
        .to raise_error(described_class::NotUuidPrimaryKey)
    end

    # ArgumentError のまま飛ばすと decode_or_nil のような rescue に拾われかねない
    it "ArgumentError ではない (静かに握りつぶされない)" do
      expect(described_class::NotUuidPrimaryKey.ancestors).not_to include ArgumentError
      expect { described_class.encode_primary_key(1) }.to raise_error(StandardError)
    end
  end

  describe ".decode_or_nil" do
    it "正しい値は decode と同じ" do
      encoded = described_class.encode(V7)
      expect(described_class.decode_or_nil(encoded)).to eq V7
    end

    it "不正な値は nil (例外にしない)" do
      expect(described_class.decode_or_nil("1" * 21)).to be_nil
      expect(described_class.decode_or_nil(V7)).to be_nil
      expect(described_class.decode_or_nil("0" * 22)).to be_nil
      expect(described_class.decode_or_nil(described_class::ALPHABET[-1] * 22)).to be_nil
      expect(described_class.decode_or_nil(nil)).to be_nil
      expect(described_class.decode_or_nil(1)).to be_nil
    end
  end

  describe "往復" do
    it "無作為な UUID 1000 個が往復する" do
      1000.times do
        uuid = SecureRandom.uuid
        expect(described_class.decode(described_class.encode(uuid))).to eq uuid
      end
    end

    it "両端と境界値が往復する" do
      [ ZERO, MAX, V7,
        "00000000-0000-0000-0000-000000000001",
        "ffffffff-ffff-ffff-ffff-fffffffffffe",
        "00000000-0000-0000-0000-0000000000ff",
        "0fffffff-ffff-ffff-ffff-ffffffffffff" ].each do |uuid|
        expect(described_class.decode(described_class.encode(uuid))).to eq uuid
      end
    end

    it "1 つの UUID に表現は 1 つだけ (長さ固定)" do
      encoded = described_class.encode("00000000-0000-0000-0000-000000000005")
      expect(encoded.length).to eq 22
      # 短い表現 ("6") は 22 文字でないので decode が受け付けない
      expect { described_class.decode("6") }.to raise_error(ArgumentError)
    end
  end

  describe "順序" do
    # UUIDv7 は時刻順なので、Base58 の辞書順がそのまま作成順になる。
    # アルファベットが ASCII 昇順に並んでいることに依存する
    it "Base58 の辞書順は UUID の大小と一致する" do
      uuids = Array.new(200) { SecureRandom.uuid }.sort
      encoded = uuids.map { |uuid| described_class.encode(uuid) }

      expect(encoded).to eq encoded.sort
    end

    it "アルファベットは ASCII の昇順" do
      expect(described_class::ALPHABET.chars).to eq described_class::ALPHABET.chars.sort
    end
  end

  describe ".uuid?" do
    it "ハイフンつきの正規形 (小文字) だけを true にする" do
      expect(described_class.uuid?(V7)).to be true
      expect(described_class.uuid?(ZERO)).to be true
      expect(described_class.uuid?(MAX)).to be true
    end

    # PostgreSQL の uuid 型は大文字小文字を区別しないので、大文字を通すと
    # 「DB では一致するのに Ruby の文字列比較では一致しない」値ができてしまう
    # (Stock::Allocator が「指定したロットは使い切り」と誤判断して別のロットから引く)
    it "大文字の 16 進は false (Ruby の文字列比較とずれるため)" do
      expect(described_class.uuid?(V7.upcase)).to be false
      expect(described_class.uuid?(MAX.upcase)).to be false
      expect(described_class.uuid?("01A0C29B-28c1-7803-af0e-0a9beb8926dd")).to be false
    end

    it "それ以外は false" do
      expect(described_class.uuid?(V7.delete("-"))).to be false
      expect(described_class.uuid?(described_class.encode(V7))).to be false
      expect(described_class.uuid?("1")).to be false
      expect(described_class.uuid?("")).to be false
      expect(described_class.uuid?(nil)).to be false
      expect(described_class.uuid?(1)).to be false
      expect(described_class.uuid?([ V7 ])).to be false
      expect(described_class.uuid?("#{V7}\n")).to be false
    end
  end
end
