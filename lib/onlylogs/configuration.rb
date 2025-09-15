# frozen_string_literal: true

module Onlylogs
  class Configuration
    attr_accessor :allowed_files, :default_log_file_path

    def initialize
      @allowed_files = default_allowed_files
      @default_log_file_path = default_log_file_path_value
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
end
