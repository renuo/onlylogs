# frozen_string_literal: true

module Onlylogs
  class LogsChannel < ActionCable::Channel::Base
    def subscribed
      # Wait for the client to send the cursor position
      # start_log_watcher will be called from the initialize_watcher method
    end

    def initialize_watcher(data)
      # Decrypt and verify the file path
      begin
        encrypted_file_path = data["file_path"]
        if encrypted_file_path.present?
          file_path = Onlylogs::SecureFilePath.decrypt(encrypted_file_path)

          # Verify the decrypted path is still allowed
          unless Onlylogs.allowed_file_path?(file_path)
            Rails.logger.error "Onlylogs: Attempted to access non-allowed file: #{file_path}"
            transmit({ action: "error", content: "Access denied" })
            return
          end
        else
          # Fallback to default if no encrypted path provided
          file_path = Onlylogs.default_log_file_path
        end
      rescue Onlylogs::SecureFilePath::SecurityError => e
        Rails.logger.error "Onlylogs: Security violation - #{e.message}"
        transmit({ action: "error", content: "Access denied" })
        return
      end

      cursor_position = data["cursor_position"] || 0
      filter = data["filter"].presence
      mode = data["mode"] || "live"
      fast = data["fast"] == true || data["fast"] == "true"
      regexp_mode = data["regexp_mode"] == true || data["regexp_mode"] == "true"

      if mode == "search"
        # For search mode, read the entire file with filter and send all matching lines
        read_entire_file_with_filter(file_path, filter, fast, regexp_mode)
      else
        # For live mode, start the watcher
        start_log_watcher(file_path, cursor_position, filter, fast, regexp_mode)
      end
    end

    def unsubscribed
      stop_log_watcher
    end

    private

    def start_log_watcher(file_path, cursor_position, filter = nil, fast = false, regexp_mode = false)
      return if @log_watcher_running

      @log_watcher_running = true
      @filter = filter
      @regexp_mode = regexp_mode

      transmit({ action: "message", content: "Reading file. Please wait..." })

      klass = fast ? Onlylogs::FastFile : Onlylogs::File
      @log_file = klass.new(file_path, last_position: cursor_position)

      @log_watcher_thread = Thread.new do
        Rails.logger.info "Starting log file watcher for connection #{connection.connection_identifier} from cursor position #{cursor_position} for file: #{file_path}."
        Rails.logger.silence(Logger::ERROR) do

          @log_file.watch do |new_lines|
            break unless @log_watcher_running

            # Collect all filtered lines from this batch
            lines_to_send = []

            new_lines.each do |log_line|
              if @filter.present? && !Onlylogs::Grep.match_line?(log_line.text, @filter, regexp_mode: @regexp_mode)
                next
              end

              lines_to_send << {
                line_number: log_line.number,
                html: render_log_line(log_line)
              }
            end

            if lines_to_send.any?
              transmit({
                         action: "append_logs",
                         lines: lines_to_send
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

    def read_entire_file_with_filter(file_path, filter = nil, fast = false, regexp_mode = false)
      klass = fast ? Onlylogs::FastFile : Onlylogs::File
      @log_file = klass.new(file_path, last_position: 0)
      start_time = Time.now

      # Initialize batching for search mode
      @batch_sender = BatchSender.new(self)
      @batch_sender.start

      Rails.logger.silence(Logger::ERROR) do
        @log_file.grep(filter, regexp_mode: regexp_mode) do |log_line|
          # Add to batch buffer (sender thread will handle sending)
          @batch_sender.add_line({
                                   line_number: log_line.number,
                                   html: render_log_line(log_line)
                                 })
        end
      end

      # Stop batch sender and flush any remaining lines
      @batch_sender.stop

      duration = Time.now - start_time
      puts "Completed grep of file #{file_path} in #{duration.round(2)} seconds"
    end

    def render_log_line(log_line)
      "<pre data-line-number=\"#{log_line.number}\">" \
        "<span class=\"line-number\">#{log_line.parsed_number}</span>#{log_line.parsed_text}</pre>"
    end
  end
end
