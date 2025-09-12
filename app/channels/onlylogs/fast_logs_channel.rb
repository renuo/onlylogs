# frozen_string_literal: true

module Onlylogs
  class FastLogsChannel < ActionCable::Channel::Base
    def subscribed
      # Wait for the client to send the cursor position
      # start_log_watcher will be called from the initialize_watcher method
    end

    def initialize_watcher(data)
      file_path = data["file_path"].presence || Rails.root.join("log/#{Rails.env}.log")
      cursor_position = data["cursor_position"] || 0
      start_log_watcher(file_path, cursor_position)
    end

    def unsubscribed
      stop_log_watcher
    end

    private

    def start_log_watcher(file_path, cursor_position)
      return if @log_watcher_running

      @log_watcher_running = true
      @log_file = Onlylogs::FastFile.new(file_path, last_position: cursor_position)
      last_line_number = 0

      @log_watcher_thread = Thread.new do
        Rails.logger.info "Starting log file watcher for connection #{connection.connection_identifier} from cursor position #{cursor_position} for file: #{file_path}."

        @log_file.watch do |new_lines|
          break unless @log_watcher_running

          Rails.logger.silence(Logger::ERROR) do
            new_lines.each do |line|
              last_line_number += 1
              log_line = Onlylogs::LogLine.new(last_line_number, line)
              transmit({
                action: "append_logs",
                lines: [ {
                  line_number: last_line_number,
                  html: render_log_line(log_line)
                } ]
              })
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

    def render_log_line(log_line)
      ApplicationController.renderer.render(partial: "onlylogs/shared/log_line", locals: { log_line: log_line })
    end
  end
end
