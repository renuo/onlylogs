# frozen_string_literal: true

module Onlylogs
  class LogsChannel < ActionCable::Channel::Base
    def subscribed
      # Wait for the client to send the cursor position
      # start_log_watcher will be called from the initialize_watcher method
    end

    def initialize_watcher(data)
      file_path = data["file_path"].presence || Rails.root.join("log/#{Rails.env}.log")
      cursor_position = data["cursor_position"] || 0
      filter = data["filter"].presence
      mode = data["mode"] || "live"

      if mode == "search"
        # For search mode, read the entire file with filter and send all matching lines
        read_entire_file_with_filter(file_path, filter)
      else
        # For live mode, start the watcher
        start_log_watcher(file_path, cursor_position, filter)
      end
    end

    def unsubscribed
      stop_log_watcher
    end

    private

    def start_log_watcher(file_path, cursor_position, filter = nil)
      return if @log_watcher_running

      @log_watcher_running = true
      @filter = filter

      transmit({ action: "message", content: "Reading file. Please wait..." })

      @log_file = Onlylogs::File.new(file_path, last_position: cursor_position)


      @log_watcher_thread = Thread.new do
        Rails.logger.info "Starting log file watcher for connection #{connection.connection_identifier} from cursor position #{cursor_position} for file: #{file_path}."


         @log_file.watch do |new_lines|
           break unless @log_watcher_running

           Rails.logger.silence(Logger::ERROR) do
             new_lines.each do |log_line|
               # Apply filter if present
               if @filter.present? && !Onlylogs::Grep.match_line?(log_line.text, @filter)
                 next
               end

               transmit(
                 { action: "append_log",
                   line_number: log_line.number,
                   content: log_line,
                   html: render_log_line(log_line) }
               )
             end
           end
         end
      rescue StandardError => e
        Rails.logger.error "Log watcher error: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
      ensure
        @log_watcher_running = false
      end
    end

    def stop_log_watcher
      return unless @log_watcher_running

      Rails.logger.info "Stopping log file watcher for connection #{connection.connection_identifier}"
      @log_watcher_running = false

      return unless @log_watcher_thread&.alive?

      @log_watcher_thread.kill
      @log_watcher_thread.join(1)
    end

    def read_entire_file_with_filter(file_path, filter = nil)
      Rails.logger.info "Reading entire file with filter: #{filter}"
      @log_file = Onlylogs::File.new(file_path, last_position: 0)
      start_time = Time.now
      @log_file.grep(filter) do |log_line|
        fetched_time = Time.now
        Rails.logger.info "Fetched log line #{log_line.number} after #{((fetched_time - start_time) * 1000).round(2)} ms"
        Rails.logger.silence(Logger::ERROR) do
          transmit(
            { action: "append_log",
              line_number: log_line.number,
              content: log_line,
              html: render_log_line(log_line) }
          )
        end
        transmission_time = Time.now
        Rails.logger.info "Transmitted log line #{log_line.number} after #{((transmission_time - fetched_time) * 1000).round(2)} ms"
        start_time = Time.now
      end
    end

    def render_log_line(log_line)
      ApplicationController.renderer.render(partial: "onlylogs/shared/log_line", locals: { log_line: log_line })
    end
  end
end
