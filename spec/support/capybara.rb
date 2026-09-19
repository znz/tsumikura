# system spec の既定ドライバは rack_test (ブラウザを起動せず高速)。
# js: true が付いた spec だけ、スマホ幅の headless Chrome を使う。
# Chrome (chromium) が無いローカル環境では、Selenium Manager にブラウザ/driver を
# ダウンロードさせず、素直に skip する。GitHub Actions では Chrome がある前提で常に実行する
# (bin/ci も ENV["CI"] を立てるので、CI ではなく GITHUB_ACTIONS で判定する)。
module SystemSpecBrowser
  CHROME_EXECUTABLES = %w[google-chrome google-chrome-stable chromium chromium-browser].freeze

  def self.chrome_installed?
    ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
      CHROME_EXECUTABLES.any? { |name| File.executable?(File.join(dir, name)) }
    end
  end
end

RSpec.configure do |config|
  config.before(:each, type: :system) do
    driven_by :rack_test
  end

  config.before(:each, type: :system, js: true) do
    if ENV["GITHUB_ACTIONS"].blank? && !SystemSpecBrowser.chrome_installed?
      skip "Chrome (chromium) が見つからないため js: true の system spec を skip します"
    end

    driven_by :selenium, using: :headless_chrome, screen_size: [ 390, 844 ]
  end
end
