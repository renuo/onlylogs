# frozen_string_literal: true

Onlylogs.configure do |config|
  # config.http_basic_auth_user = "dev"
  # config.http_basic_auth_password = "dev"

  # config.parent_controller = "ApplicationController"
  config.disable_basic_authentication = true
  config.max_line_matches = 1_000_000_000 # one gazillion of millions
  # config.ripgrep_enabled = false
  #
  # The home page links every fixture in that directory, .txt ones included, so
  # they have to be allowed here or the link 500s on "File path not allowed".
  config.log_file_patterns = [
    Onlylogs::Engine.root.join("test", "fixtures", "files", "*.log"),
    Onlylogs::Engine.root.join("test", "fixtures", "files", "*.txt"),
    Rails.root.join("log", "*.log")
  ]
end
