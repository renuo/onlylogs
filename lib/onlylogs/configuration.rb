# frozen_string_literal: true

module Onlylogs
  class Configuration
    attr_accessor :allowed_files, :default_log_file_path, :basic_auth_user, :basic_auth_password,
                  :parent_controller, :disable_basic_authentication, :ripgrep_enabled, :editor,
                  :max_line_matches

    def initialize
      @allowed_files = default_allowed_files
      @default_log_file_path = default_log_file_path_value
      @basic_auth_user = default_basic_auth_user
      @basic_auth_password = default_basic_auth_password
      @parent_controller = nil
      @disable_basic_authentication = false
      @ripgrep_enabled = default_ripgrep_enabled
      @editor = default_editor
      @max_line_matches = 100000
    end

    def configure
      yield self
    end

    def default_editor
      if (credentials_editor = Rails.application.credentials.dig(:onlylogs, :editor))
        return credentials_editor
      end
      
      # 2. Check environment variables (ONLYLOGS_EDITOR > RAILS_EDITOR > EDITOR)
      if ENV["ONLYLOGS_EDITOR"]
        return ENV["ONLYLOGS_EDITOR"].to_sym
      end
      
      if ENV["RAILS_EDITOR"]
        return ENV["RAILS_EDITOR"].to_sym
      end
      
      if ENV["EDITOR"]
        return ENV["EDITOR"].to_sym
      end
      
      # 3. Default fallback
      :vscode
    end

    def default_allowed_files
      # Default to environment-specific log files (without rotation suffixes)
      [
        Rails.root.join("log/#{Rails.env}.log")
      ]
    end

    def default_log_file_path_value
      Rails.root.join("log/#{Rails.env}.log").to_s
    end

    def default_basic_auth_user
      ENV["ONLYLOGS_BASIC_AUTH_USER"] || Rails.application.credentials.dig(:onlylogs, :basic_auth_user)
    end

    def default_basic_auth_password
      ENV["ONLYLOGS_BASIC_AUTH_PASSWORD"] || Rails.application.credentials.dig(:onlylogs, :basic_auth_password)
    end

    def default_ripgrep_enabled
      system("which rg > /dev/null 2>&1")
    end
  end

  def self.configuration
    @configuration ||= Configuration.new
  end

  def self.configure
    yield configuration
  end

  def self.allowed_file_path?(file_path)
    path = ::File.expand_path(file_path.to_s)

    configuration.allowed_files.any? do |pattern|
      pat = ::File.expand_path(pattern.to_s)
      ::File.fnmatch?(pat, path, ::File::FNM_PATHNAME | ::File::FNM_DOTMATCH)
    end
  end

  def self.default_log_file_path
    configuration.default_log_file_path
  end

  def self.basic_auth_user
    configuration.basic_auth_user
  end

  def self.basic_auth_password
    configuration.basic_auth_password
  end

  def self.parent_controller
    configuration.parent_controller
  end

  def self.disable_basic_authentication?
    configuration.disable_basic_authentication
  end

  def self.basic_auth_configured?
    basic_auth_user.present? && basic_auth_password.present?
  end

  def self.ripgrep_enabled?
    configuration.ripgrep_enabled
  end

  def self.editor
    configuration.default_editor
  end

  def self.editor=(editor_symbol)
    configuration.editor = editor_symbol
    # Clear the cached editor instance when editor changes
    Onlylogs::FilePathParser.clear_editor_cache
  end

  def self.max_line_matches
    configuration.max_line_matches
  end
end
