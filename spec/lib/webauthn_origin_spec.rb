# DB も Rails も要らない (config/initializers/webauthn.rb が起動前に使う PORO)。
# 予測のロジック (spec/models/forecast/) と同じく spec_helper だけで回す
require "spec_helper"
require "uri"
require_relative "../../lib/webauthn_origin"

RSpec.describe WebauthnOrigin do
  describe ".normalize" do
    it "スキーム + ホストはそのまま" do
      expect(described_class.normalize("https://tsumikura.example.com")).to eq "https://tsumikura.example.com"
    end

    # 末尾スラッシュ 1 つで全 ceremony が静かに失敗するので、ここで落とす
    it "末尾のスラッシュを落とす" do
      expect(described_class.normalize("https://tsumikura.example.com/")).to eq "https://tsumikura.example.com"
    end

    it "パス・クエリ・フラグメントを落とす" do
      expect(described_class.normalize("https://tsumikura.example.com/account?a=1#b"))
        .to eq "https://tsumikura.example.com"
    end

    it "前後の空白を落とす" do
      expect(described_class.normalize("  https://tsumikura.example.com \n")).to eq "https://tsumikura.example.com"
    end

    it "非標準ポートは残す" do
      expect(described_class.normalize("https://tsumikura.example.com:8443")).to eq "https://tsumikura.example.com:8443"
      expect(described_class.normalize("http://localhost:3000")).to eq "http://localhost:3000"
    end

    it "既定のポートは落とす" do
      expect(described_class.normalize("https://tsumikura.example.com:443")).to eq "https://tsumikura.example.com"
      expect(described_class.normalize("http://localhost:80")).to eq "http://localhost"
    end

    # 例外を投げると「未設定でもアプリは起動する」方針が壊れる
    it "壊れた値・スキームなし・空は nil (例外にしない)" do
      [ nil, "", "   ", "tsumikura.example.com", "https://", "ht tp://x", "://x",
        "ftp://tsumikura.example.com", "javascript:alert(1)" ].each do |value|
        expect { described_class.normalize(value) }.not_to raise_error, "normalize(#{value.inspect})"
        expect(described_class.normalize(value)).to be_nil, "normalize(#{value.inspect})"
      end
    end
  end

  describe ".host" do
    it "ホスト名だけを返す (RP ID に使う)" do
      expect(described_class.host("https://tsumikura.example.com:8443/x")).to eq "tsumikura.example.com"
      expect(described_class.host("http://localhost:3000")).to eq "localhost"
    end

    it "取り出せなければ nil" do
      [ nil, "", "tsumikura.example.com", "https://" ].each do |value|
        expect(described_class.host(value)).to be_nil, "host(#{value.inspect})"
      end
    end
  end
end
