# frozen_string_literal: true

require "time"
require "securerandom"

module Onlylogs
  # Appends realistic fake log lines to a file, forever, for manual testing of
  # live streaming and of the UI.
  #
  # Lines are written in the onlylogs format: what a Rails app logging through
  # Onlylogs::Logger with `config.log_tags = [:request_id]` actually produces.
  #
  #   Onlylogs::ContinuousLogWriter.new("log/development.log", logs_per_batch: 5, interval: 1).call
  #
  # This is a development tool. It is deliberately plain Ruby (no Rails, no
  # ActiveSupport) so it can run without booting an app, and it is not required
  # by `onlylogs.rb` — require it explicitly where you need it.
  class ContinuousLogWriter
    # [method, path, format, controller, action]
    ROUTES = [
      ["GET", "/workflow_events", "html", "WorkflowEventsController", "index"],
      ["GET", "/materials/search", "html", "MaterialsController", "search"],
      ["GET", "/projects/42", "html", "ProjectsController", "show"],
      ["POST", "/sessions", "html", "SessionsController", "create"],
      ["GET", "/api/logs", "json", "Api::LogsController", "ingest"],
      ["GET", "/dashboard", "html", "DashboardController", "index"]
    ].freeze

    STATUSES = [200, 200, 200, 200, 302, 404, 500].freeze

    attr_reader :counter

    def initialize(path, logs_per_batch: 1, interval: 2, out: $stdout)
      @path = path.to_s
      @logs_per_batch = logs_per_batch.to_i
      @interval = interval.to_f
      @out = out
      @counter = 0
    end

    # Runs until interrupted (Ctrl+C).
    def call
      loop do
        @logs_per_batch.times { write_line }
        sleep @interval
      end
    rescue Interrupt
      @out.puts "\nStopped after #{@counter} log(s)."
    end

    # One log line, in the onlylogs format:
    # [request_id] [ISO8601] [severity] method=.. path=.. controller=.. action=.. duration=.. ..
    def build_line
      method, path, format, controller, action = ROUTES.sample
      status = STATUSES.sample
      severity = severity_for(status)

      db = (rand * 60).round(2)
      view = (rand * 30).round(2)
      duration = (db + view + rand * 10).round(2)
      params = format == "json" ? "{}" : %({"context_id" => "#{SecureRandom.uuid}"})

      "[#{SecureRandom.uuid}] [#{Time.now.iso8601}] [#{severity}] " \
        "method=#{method} path=#{path} format=#{format} controller=#{controller} action=#{action} " \
        "status=#{status} allocations=#{rand(5_000..40_000)} duration=#{duration} view=#{view} db=#{db} " \
        "params=#{params} sys_manager_id=#{rand(1..200)}"
    end

    private

    def severity_for(status)
      return "E" if status >= 500
      return "W" if status >= 400

      "I"
    end

    def write_line
      @counter += 1
      line = build_line
      File.open(@path, "a") { |f| f.puts(line) }
      @out.puts "✓ #{@counter}: #{line[0, 80]}..."
    end
  end
end
