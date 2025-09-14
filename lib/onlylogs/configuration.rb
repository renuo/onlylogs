# frozen_string_literal: true

module Onlylogs
  class Configuration
    attr_accessor :allowed_files

    def initialize
      @allowed_files = default_allowed_files
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
  end

  def self.configuration
    @configuration ||= Configuration.new
  end

  def self.configure
    yield configuration
  end

  # Check if a file path is allowed (including rotated versions)
  def self.allowed_file_path?(file_path)
    normalized_path = ::File.expand_path(file_path.to_s)

    configuration.allowed_files.any? do |allowed_pattern|
      allowed_path = ::File.expand_path(allowed_pattern.to_s)

      # Check if it's an exact match
      return true if allowed_path == normalized_path

      # Check if it's a rotated version of the allowed file
      allowed_basename = ::File.basename(allowed_path)
      normalized_basename = ::File.basename(normalized_path)

      # Check if they're in the same directory
      if ::File.dirname(allowed_path) == ::File.dirname(normalized_path)
        # Check if normalized path matches the pattern: basename.number
        if normalized_basename.match?(/^#{Regexp.escape(allowed_basename)}\.\d+$/)
          return true
        end
      end

      false
    end
  end
end
