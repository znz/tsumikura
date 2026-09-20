require "rails_helper"

# PWA の manifest と service worker は Rails::PwaController が返す。
# ApplicationController を継承しないので認証を通らない = **未ログインでも取得できる**。
# 「ホーム画面に追加」はログイン前にも行われるので、これは仕様どおり
# (docs/spec/04-notifications.md 1 節)。ここでその前提を固定する。
RSpec.describe "PWA", type: :request do
  describe "GET /manifest.json" do
    it "未ログインでも取得できる" do
      get pwa_manifest_path(format: :json)

      expect(response).to have_http_status(:ok)
    end

    it "JSON として読める" do
      get pwa_manifest_path(format: :json)

      expect { JSON.parse(response.body) }.not_to raise_error
    end

    it "ホーム画面に追加できる最低限の項目がそろっている" do
      get pwa_manifest_path(format: :json)
      manifest = JSON.parse(response.body)

      expect(manifest).to include(
        "name" => "つみくら", "short_name" => "つみくら", "lang" => "ja",
        "start_url" => "/", "scope" => "/", "display" => "standalone"
      )
      expect(manifest["theme_color"]).to be_present
      expect(manifest["background_color"]).to be_present
    end

    it "参照しているアイコンが実在する" do
      get pwa_manifest_path(format: :json)

      JSON.parse(response.body).fetch("icons").each do |icon|
        expect(Rails.public_path.join(icon.fetch("src").delete_prefix("/"))).to exist
      end
    end

    it "ショートカットのリンク先がルーティングにある" do
      get pwa_manifest_path(format: :json)

      JSON.parse(response.body).fetch("shortcuts").each do |shortcut|
        expect { Rails.application.routes.recognize_path(shortcut.fetch("url")) }.not_to raise_error
      end
    end
  end

  describe "GET /service-worker" do
    # ブラウザは Accept: */* で取りに来る (拡張子の無いパスなので明示する)
    def get_service_worker
      get pwa_service_worker_path, headers: { "Accept" => "*/*" }
    end

    it "未ログインでも取得できる" do
      get_service_worker

      expect(response).to have_http_status(:ok)
    end

    it "JavaScript として返す (MIME が違うとブラウザが登録を拒む)" do
      get_service_worker

      expect(response.media_type).to be_in %w[ text/javascript application/javascript ]
    end

    it "push と notificationclick を扱う" do
      get_service_worker

      expect(response.body).to include 'addEventListener("push"'
      expect(response.body).to include 'addEventListener("notificationclick"'
      expect(response.body).to include "showNotification"
    end

    it "キャッシュ (オフライン対応) は入れない" do
      get_service_worker

      expect(response.body).not_to include 'addEventListener("fetch"'
      expect(response.body).not_to include "caches.open"
    end
  end

  describe "レイアウト" do
    before { sign_in create(:user) }

    it "manifest へのリンクを出す" do
      get root_path

      expect(response.parsed_body.css(%(link[rel="manifest"]))).to be_any
    end

    it "theme-color の meta を出す" do
      get root_path

      expect(response.parsed_body.css(%(meta[name="theme-color"]))).to be_any
    end

    it "VAPID の公開鍵は全ページには置かない (使うのはアカウント設定だけ)" do
      configure_vapid

      get root_path

      expect(response.parsed_body.css(%(meta[name="vapid-public-key"]))).to be_empty
    end
  end
end
