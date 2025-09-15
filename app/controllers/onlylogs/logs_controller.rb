# frozen_string_literal: true

module Onlylogs
  class LogsController < ApplicationController
    def index
      @max_lines = (params[:max_lines] || 100).to_i

      # Get the file path from params or use default
      @log_file_path = params[:log_file_path] || default_log_file_path

      @filter = params[:filter]
      @autoscroll = params[:autoscroll] != "false"
      @mode = @filter.blank? ? (params[:mode] || "live") : "search" # "live" or "search"
      @fast = params[:fast] == "true"
    end

    private

    def default_log_file_path
      # "/Users/alessandrorodi/RenuoWorkspace/onlylogs/test/fixtures/files/very_big.log"
      Onlylogs.default_log_file_path
    end
  end
end
