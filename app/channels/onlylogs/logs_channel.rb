# frozen_string_literal: true

module Onlylogs
  class LogsChannel < ActionCable::Channel::Base
    def subscribed
      # Rails.logger.info "Client subscribed to Onlylogs::LogsChannel"
      # Wait for the client to send the cursor position
      # start_log_watcher will be called from the initialize_watcher method
    end

    def initialize_watcher(data)
      cleanup_existing_operations

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
      regexp_mode = data["regexp_mode"] == true || data["regexp_mode"] == "true"
      start_position = data["start_position"]&.to_i || 0
      end_position = data["end_position"]&.to_i

      if mode == "search"
        # For search mode, read the entire file with filter and send all matching lines
        read_entire_file_with_filter(file_path, filter, regexp_mode, start_position, end_position)
      else
        # For live mode, start the watcher
        start_log_watcher(file_path, cursor_position, filter, regexp_mode)
      end
    end

    def stop_watcher
      cleanup_existing_operations
      transmit({ action: "finish", content: "Search stopped." })
    end

    def unsubscribed
      cleanup_existing_operations
    end

    private

    def cleanup_existing_operations
      if @batch_sender
        @batch_sender.stop
        @batch_sender = nil
      end

      stop_log_watcher
    end

    def start_log_watcher(file_path, cursor_position, filter = nil, regexp_mode = false)
      return if @log_watcher_running

      @log_watcher_running = true
      @filter = filter
      @regexp_mode = regexp_mode

      transmit({ action: "message", content: "Reading file. Please wait..." })

      @log_file = Onlylogs::File.new(file_path, last_position: cursor_position)

      transmit({ action: "message", content: "" })

      @log_watcher_thread = Thread.new do
        Rails.logger.silence(Logger::ERROR) do
          @log_file.watch do |new_lines|
            break unless @log_watcher_running

            # Collect all filtered lines from this batch
            lines_to_send = []

            new_lines.each do |log_line|
              # Filters in live mode are not yet implemented
              # if @filter.present? && !Onlylogs::Grep.match_line?(log_line.text, @filter, regexp_mode: @regexp_mode)
              #   next
              # end

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

      @log_watcher_running = false

      return unless @log_watcher_thread&.alive?

      @log_watcher_thread.kill
      @log_watcher_thread.join(1)
    end

    def read_entire_file_with_filter(file_path, filter = nil, regexp_mode = false, start_position = 0, end_position = nil)
      @log_watcher_running = true
      @log_file = Onlylogs::File.new(file_path, last_position: 0)

      transmit({ action: "message", content: "Searching..." })

      @batch_sender = BatchSender.new(self)
      @batch_sender.start

      line_count = 0

      Rails.logger.silence(Logger::ERROR) do
        @log_file.grep(filter, regexp_mode: regexp_mode, start_position: start_position, end_position: end_position) do |log_line|
          return if @batch_sender.nil?

          # Add to batch buffer (sender thread will handle sending)
          @batch_sender.add_line({
                                   line_number: log_line.number,
                                   html: render_log_line(log_line)
                                 })

          line_count += 1
        end
      end

      # Stop batch sender and flush any remaining lines
      @batch_sender.stop

      # Send completion message
      if line_count >= Onlylogs.max_line_matches
        transmit({ action: "finish", content: "Search finished. Search results limit reached." })
      else
        transmit({ action: "finish", content: "Search finished." })
      end

      @log_watcher_running = false
    end

    def render_log_line(log_line)
      "<pre data-line-number=\"#{log_line.number}\">" \
        "<span class=\"line-number\">#{log_line.parsed_number}</span>#{log_line.parsed_text}</pre>"
    end
  end
end
