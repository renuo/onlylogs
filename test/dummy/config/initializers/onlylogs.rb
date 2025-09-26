# frozen_string_literal: true

Onlylogs.configure do |config|
  # config.http_basic_auth_user = "dev"
  # config.http_basic_auth_password = "dev"

  # config.parent_controller = "ApplicationController"
  config.disable_basic_authentication = true
  config.max_line_matches = 1_000_000
  # config.ripgrep_enabled = false
  #
  config.allowed_files = [
    Onlylogs::Engine.root.join("test", "fixtures", "files", "*.log"),
    Rails.root.join("log", "*.log")
  ]
end
