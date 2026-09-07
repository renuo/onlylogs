# frozen_string_literal: true

require "time"
require "securerandom"

module Onlylogs
  # Appends realistic fake Rails request logs to a file, forever, for manual
  # testing of live streaming and of the UI.
  #
  # Each "log" is a full request: Started / Processing / Parameters / SQL /
  # Completed, with the ANSI colors ActiveRecord and ActionView emit in
  # development, prefixed the way Onlylogs::Logger with
  # `config.log_tags = [:request_id]` prefixes lines.
  #
  #   Onlylogs::ContinuousLogWriter.new("log/development.log", logs_per_batch: 5, interval: 1).call
  #
  # This is a development tool. It is deliberately plain Ruby (no Rails, no
  # ActiveSupport) so it can run without booting an app, and it is not required
  # by `onlylogs.rb` — require it explicitly where you need it.
  class ContinuousLogWriter
    # [method, path, controller, action, format, model]
    ROUTES = [
      ["GET", "/workflow_events", "WorkflowEventsController", "index", "html", "WorkflowEvent"],
      ["GET", "/materials/search?q=steel", "MaterialsController", "search", "html", "Material"],
      ["GET", "/projects/42", "ProjectsController", "show", "html", "Project"],
      ["POST", "/sessions", "SessionsController", "create", "html", "User"],
      ["POST", "/api/logs", "Api::LogsController", "ingest", "json", "LogEntry"],
      ["GET", "/dashboard", "DashboardController", "index", "html", "Widget"]
    ].freeze

    STATUSES = [200, 200, 200, 200, 302, 404, 500].freeze

    STATUS_TEXTS = {
      200 => "OK", 302 => "Found", 404 => "Not Found", 500 => "Internal Server Error"
    }.freeze

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
        @logs_per_batch.times { write_request }
        sleep @interval
      end
    rescue Interrupt
      @out.puts "\nStopped after #{@counter} line(s)."
    end

    # All the lines of one request, each in the onlylogs format:
    # [request_id] [ISO8601] [severity] <what Rails logs in development>
    def build_request_lines(status: STATUSES.sample)
      method, path, controller, action, format, model = ROUTES.sample
      request_id = SecureRandom.uuid
      time = Time.now

      messages = request_messages(method, path, controller, action, format, model, status, time)
      messages.map { |severity, text| "[#{request_id}] [#{time.iso8601}] [#{severity}] #{text}" }
    end

    private

    BOLD = "\e[1m"
    CLEAR = "\e[0m"
    COLORS = {red: 31, green: 32, yellow: 33, blue: 34, magenta: 35, cyan: 36, white: 37}.freeze

    def paint(text, color, bold: true)
      prefix = bold ? BOLD : ""
      "#{prefix}\e[#{COLORS.fetch(color)}m#{text}#{CLEAR}"
    end

    def request_messages(method, path, controller, action, format, model, status, time)
      db = (rand * 20 + 0.5).round(1)
      views = (rand * 40 + 1).round(1)
      total = (db + views + rand * 15).round

      messages = []
      messages << ["I", %(Started #{method} "#{path}" for 127.0.0.1 at #{time})]
      messages << ["I", "Processing by #{controller}##{action} as #{format.upcase}"]
      messages << ["I", "  Parameters: #{parameters(method, path)}"] if method == "POST" || path.include?("?")
      messages.concat(sql_messages(method, model, db, status))
      messages.concat(render_messages(controller, action, format, views)) if status != 500
      messages << ["I", completed(status, total, views, db)]
      messages.concat(error_messages(controller, action, model)) if status == 500
      messages
    end

    def parameters(method, path)
      if method == "POST"
        %({"authenticity_token" => "[FILTERED]", "session" => {"email" => "user@example.com", "password" => "[FILTERED]"}})
      else
        query = path.split("?").last
        key, value = query.split("=")
        %({"#{key}" => "#{value}"})
      end
    end

    def sql_messages(method, model, db, status)
      table = "#{model.gsub(/([a-z])([A-Z])/, '\1_\2').downcase}s"
      messages = []
      messages << ["D", sql("#{model} Load (#{(db / 2).round(1)}ms)", :cyan,
        %(SELECT "#{table}".* FROM "#{table}" WHERE "#{table}"."id" = $1 LIMIT $2), :blue)]
      messages << ["D", sql("User Load (#{(rand * 2).round(1)}ms)", :cyan,
        %(SELECT "users".* FROM "users" WHERE "users"."id" = $1 LIMIT $2 /*action='show'*/), :magenta)]

      if method == "POST" && status < 400
        messages << ["D", sql("TRANSACTION (0.1ms)", :yellow, "BEGIN", :blue)]
        messages << ["D", sql("#{model} Create (#{(db / 2).round(1)}ms)", :green,
          %(INSERT INTO "#{table}" ("created_at", "updated_at") VALUES ($1, $2) RETURNING "id"), :magenta)]
        messages << ["D", sql("TRANSACTION (0.3ms)", :yellow, "COMMIT", :blue)]
      end
      messages
    end

    def sql(name, name_color, statement, statement_color)
      "  #{paint(name, name_color)}  #{paint(statement, statement_color)}"
    end

    def render_messages(controller, action, format, views)
      return [] unless format == "html"

      template = "#{controller.sub("Controller", "").gsub(/([a-z])([A-Z])/, '\1_\2').downcase}/#{action}.html.erb"
      [
        ["D", "  Rendering layout layouts/application.html.erb"],
        ["D", "  Rendering #{template} within layouts/application"],
        ["I", "  Rendered #{template} within layouts/application (Duration: #{views}ms | GC: 0.2ms)"]
      ]
    end

    def completed(status, total, views, db)
      breakdown = (status == 500) ? "ActiveRecord: #{db}ms" : "Views: #{views}ms | ActiveRecord: #{db}ms"
      "Completed #{status} #{STATUS_TEXTS.fetch(status)} in #{total}ms (#{breakdown} | Allocations: #{rand(5_000..40_000)})"
    end

    def error_messages(controller, action, model)
      variable = model.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
      [
        ["F", ""],
        ["F", paint("NoMethodError (undefined method 'name' for nil):", :red)],
        ["F", ""],
        ["F", "app/models/#{variable}.rb:42:in '#{model}#display_name'"],
        ["F", "app/controllers/#{controller.gsub(/([a-z])([A-Z])/, '\1_\2').downcase}.rb:18:in '#{controller}##{action}'"]
      ]
    end

    def write_request
      lines = build_request_lines
      ::File.open(@path, "a") { |f| lines.each { |line| f.puts(line) } }
      @counter += lines.size
      summary = lines.first[/Started .*?" /] || lines.first[0, 60]
      @out.puts "✓ #{@counter} lines: #{summary}(#{lines.size} lines)"
    end
  end
end
