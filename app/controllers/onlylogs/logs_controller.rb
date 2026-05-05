# frozen_string_literal: true

module Onlylogs
  class LogsController < ApplicationController
    def index
      @max_lines = (params[:max_lines] || 100).to_i

      @available_log_files = Onlylogs.available_log_files
      @log_file_path = selected_log_file_path

      @filter = params[:filter]
      @autoscroll = params[:autoscroll] != "false"
      @mode = @filter.blank? ? (params[:mode] || "live") : "search" # "live" or "search"
    end

    def download
      if params[:log_file_path].blank?
        return render(plain: "Bad Request: missing required parameter 'log_file_path' (encrypted log file path).", status: :bad_request)
      end

      file_path = selected_log_file_path
      send_file file_path, filename: ::File.basename(file_path), disposition: :attachment
    rescue Onlylogs::SecureFilePath::SecurityError
      render plain: "Bad Request: 'log_file_path' could not be decrypted (tampered or malformed token).", status: :bad_request
    rescue Onlylogs::ForbiddenPathError
      render plain: "Forbidden: requested log file path is not in the allowed list.", status: :forbidden
    rescue ActionController::MissingFile, Errno::ENOENT
      render plain: "Not Found: log file is currently unreadable (it may have been rotated, moved, or temporarily unavailable).", status: :not_found
    end

    private

    def selected_log_file_path
      encrypted_path = params[:log_file_path]
      return default_log_file_path if encrypted_path.blank?

      decrypted_path = Onlylogs::SecureFilePath.decrypt(encrypted_path)
      if Onlylogs.file_path_permitted?(decrypted_path)
        decrypted_path
      else
        raise Onlylogs::ForbiddenPathError, "File path not allowed"
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
