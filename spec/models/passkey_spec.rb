require "rails_helper"

RSpec.describe Passkey, type: :model do
  describe "バリデーション" do
    it "ファクトリは有効" do
      expect(build(:passkey)).to be_valid
    end

    it "credential ID は必須" do
      expect(build(:passkey, external_id: nil)).not_to be_valid
    end

    it "credential ID は一意 (認証はこれだけで行を引くため)" do
      existing = create(:passkey)

      expect(build(:passkey, external_id: existing.external_id)).not_to be_valid
    end

    it "公開鍵は必須" do
      expect(build(:passkey, public_key: nil)).not_to be_valid
    end

    it "名前は必須" do
      expect(build(:passkey, nickname: " ")).not_to be_valid
    end

    it "名前は 50 文字まで" do
      expect(build(:passkey, nickname: "あ" * 51)).not_to be_valid
      expect(build(:passkey, nickname: "あ" * 50)).to be_valid
    end

    it "署名カウンタは負にできない" do
      expect(build(:passkey, sign_count: -1)).not_to be_valid
    end
  end

  describe ".recent_first" do
    it "新しい順に並べる" do
      old = create(:passkey, created_at: 3.days.ago)
      recent = create(:passkey, created_at: 1.hour.ago)

      expect(described_class.recent_first.to_a).to eq [ recent, old ]
    end
  end

  describe ".available?" do
    it "origin と RP ID が設定されていれば true (test 環境は初期化子で設定済み)" do
      expect(described_class.available?).to be true
    end

    it "origin が設定されていなければ false" do
      allow(WebAuthn.configuration).to receive(:allowed_origins).and_return([])

      expect(described_class.available?).to be false
    end
  end

  describe ".parse_credential" do
    it "JSON 文字列を Hash にする" do
      expect(described_class.parse_credential('{"type":"public-key","id":"abc"}'))
        .to eq({ "type" => "public-key", "id" => "abc" })
    end

    it "文字列でなければ TypeError (gem に渡す前に弾く)" do
      expect { described_class.parse_credential(nil) }.to raise_error TypeError
      expect { described_class.parse_credential([ "a" ]) }.to raise_error TypeError
    end

    # gem は Hash や配列の id をそのまま通すので、検証より前に走る
    # Passkey.find_by(external_id:) に配列が渡って IN 検索になってしまう
    it "id が String でなければ TypeError" do
      [ '{"id":{"a":"b"}}', '{"id":["x"]}', '{"id":1}', '{"id":null}', '{"type":"public-key"}' ].each do |json|
        expect { described_class.parse_credential(json) }.to raise_error(TypeError), json
      end
    end

    it "JSON として壊れていれば JSON::ParserError" do
      expect { described_class.parse_credential("{") }.to raise_error JSON::ParserError
    end

    it "Hash にならない JSON は TypeError" do
      expect { described_class.parse_credential("[1,2]") }.to raise_error TypeError
    end

    # コントローラは VERIFICATION_ERRORS だけを rescue する。
    # ここから漏れる例外があると 500 になる
    it "投げうる例外はすべて VERIFICATION_ERRORS で受けられる" do
      broken = [ nil, [ "a" ], { "a" => 1 }, "{", "[1,2]", "null", "",
                 '{"id":{"a":"b"}}', '{"id":["x"]}', '{"id":1}', '{"id":null}' ]

      broken.each do |input|
        caught = begin
          described_class.parse_credential(input)
          :no_error
        rescue *described_class::VERIFICATION_ERRORS
          :caught
        end

        expect(caught).to eq(:caught), "#{input.inspect} が VERIFICATION_ERRORS で受けられない"
      end
    end
  end

  describe "ユーザーとの関係" do
    it "ユーザーが必須" do
      expect(build(:passkey, user: nil)).not_to be_valid
    end

    it "無効化してもパスキーは消えない (無効化は取り消せるため)" do
      passkey = create(:passkey)

      passkey.user.update!(deactivated_at: Time.current)

      expect(described_class.exists?(passkey.id)).to be true
    end
  end
end
