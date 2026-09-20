require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Tsumikura
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    # webauthn_origin.rb は config/initializers/webauthn.rb が require_relative で読む。
    # 初期化子はオートロードより前に走るので、Zeitwerk の管理からは外す
    config.autoload_lib(ignore: %w[assets tasks webauthn_origin.rb])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # 表示は常に日本語・日本時間にする
    config.time_zone = "Asia/Tokyo"
    config.i18n.default_locale = :ja
    config.i18n.available_locales = [ :ja ]

    # リアルタイム配信は行わないので Action Cable をマウントしない
    # (app/channels を消しても ActionCable::Engine は /cable を生やし、
    #  素の Connection::Base が未認証の WebSocket を受け付けてしまう)
    config.action_cable.mount_path = nil

    # アプリ独自の設定 (config/tsumikura.yml)
    config.x.tsumikura = config_for(:tsumikura)

    # テストは RSpec + FactoryBot (Minitest のジェネレータ出力は使わない)
    config.generators do |g|
      g.test_framework :rspec,
        fixture: true, view_specs: false, helper_specs: false, routing_specs: false
      g.fixture_replacement :factory_bot, dir: "spec/factories"
    end
  end
end
