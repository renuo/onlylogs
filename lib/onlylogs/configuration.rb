# frozen_string_literal: true

module Onlylogs
  class Configuration
    attr_accessor :allowed_files, :default_log_file_path, :basic_auth_user, :basic_auth_password,
                  :parent_controller, :disable_basic_authentication

    def initialize
      @allowed_files = default_allowed_files
      @default_log_file_path = default_log_file_path_value
      @basic_auth_user = default_basic_auth_user
      @basic_auth_password = default_basic_auth_password
      @parent_controller = nil
      @disable_basic_authentication = false
    end

    def configure
      yield self
    end

    private

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
end
