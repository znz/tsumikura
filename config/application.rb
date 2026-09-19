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
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # 表示は常に日本語・日本時間にする
    config.time_zone = "Asia/Tokyo"
    config.i18n.default_locale = :ja
    config.i18n.available_locales = [ :ja ]

    # アプリ独自の設定 (config/tsumikura.yml)
    config.x.tsumikura = config_for(:tsumikura)
  end
end
