# An app that loads only the Rails core and none of its frameworks, to check that onlylogs (and
# in particular its loggers) work in apps that leave out Action Cable, Active Record, etc.
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../../Gemfile", __dir__)
require "bundler/setup"
$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)

require "rails"
# Pick the frameworks you want:
# require "active_model/railtie"
# require "active_job/railtie"
# require "active_record/railtie"
# require "active_storage/engine"
# require "action_controller/railtie"
# require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
# require "action_view/railtie"
# require "action_cable/engine"
# require "rails/test_unit/railtie"

require "onlylogs"

module MinimalApp
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.load_defaults Rails::VERSION::STRING.to_f
    config.eager_load = true
    config.secret_key_base = "minimal"
    config.logger = Onlylogs::HttpLogger.new
  end
end
