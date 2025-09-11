# frozen_string_literal: true

module Onlylogs
  class LogsController < ApplicationController
    def index
      @max_lines = (params[:max_lines] || 100).to_i

      # @log_file_path = params[:file_path] || ENV["ONLYLOGS_FILE_PATH"] || Rails.root.join("log/development.log").to_s
      @log_file_path = "/Users/alessandrorodi/RenuoWorkspace/onlylogs/test/fixtures/files/very_big.log"
      @filter = params[:filter]
      @autoscroll = params[:autoscroll] != "false"
      @mode = @filter.blank? ? (params[:mode] || "live") : "search" # "live" or "search"
    end
  end
end
