# frozen_string_literal: true

module Onlylogs
  class LogsController < ApplicationController
    def index
      @max_lines = (params[:max_lines] || 100).to_i
      @log_file_path = params[:file_path] || ENV["ONLYLOGS_FILE_PATH"] || Rails.root.join("log/development.log").to_s
      @filter = params[:filter]
      @autoscroll = params[:autoscroll] != "false"
    end
  end
end
