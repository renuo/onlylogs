# frozen_string_literal: true

module Onlylogs
  class LogsController < ApplicationController
    def index
      @max_lines = (params[:max_lines] || 100).to_i

      # Get the file path from params or use default
      @available_log_files = Onlylogs.available_log_files
      @log_file_path = selected_log_file_path

      @filter = params[:filter]
      @autoscroll = params[:autoscroll] != "false"
      @mode = @filter.blank? ? (params[:mode] || "live") : "search" # "live" or "search"
    end

    private

    def selected_log_file_path
      encrypted_path = params[:log_file_path]
      return default_log_file_path if encrypted_path.blank?

      decrypted_path = Onlylogs::SecureFilePath.decrypt(encrypted_path)
      if Onlylogs.file_path_permitted?(decrypted_path)
        decrypted_path
      else
        raise SecurityError, "File path not allowed"
      end
    end

    def default_log_file_path
      # "/Users/alessandrorodi/RenuoWorkspace/onlylogs/test/fixtures/files/very_big.log"
      configured_default = Onlylogs.default_log_file_path
      return configured_default if Onlylogs.file_path_permitted?(configured_default) && ::File.exist?(configured_default)

      @available_log_files.first&.to_s || configured_default
    end
  end
end
