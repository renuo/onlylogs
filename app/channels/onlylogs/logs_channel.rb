# frozen_string_literal: true

module Onlylogs
  class LogsChannel < ActionCable::Channel::Base
    def subscribed
      # Rails.logger.info "Client subscribed to Onlylogs::LogsChannel"
      # Wait for the client to send the cursor position
      # start_log_watcher will be called from the initialize_watcher method
    end

    def initialize_watcher(data)
      # Prevent duplicate calls with identical parameters
      if @last_initialize_params == data
        Rails.logger.info "Onlylogs: Ignoring duplicate initialize_watcher call"
        return
      end

      @last_initialize_params = data.dup
      cleanup_existing_operations

      # Decrypt and verify the file path
      begin
        encrypted_file_path = data["file_path"]
        if encrypted_file_path.present?
          file_path = Onlylogs::SecureFilePath.decrypt(encrypted_file_path)

          # Verify the decrypted path is still allowed
          unless Onlylogs.file_path_permitted?(file_path)
            Rails.logger.error "Onlylogs: Attempted to access non-allowed file: #{file_path}"
            transmit({action: "error", content: "Access denied"})
            return
          end
        else
          # Fallback to default if no encrypted path provided
          file_path = Onlylogs.default_log_file_path
        end
      rescue Onlylogs::SecureFilePath::SecurityError => e
        Rails.logger.error "Onlylogs: Security violation - #{e.message}"
        transmit({action: "error", content: "Access denied"})
        return
      end

      # Check if the file is a text file
      unless Onlylogs::File.text_file?(file_path)
        transmit({action: "error", content: "Cannot read file: File is not a text file"})
        return
      end

      filter = data["filter"].presence
      mode = data["mode"] || "live"
      regexp_mode = data["regexp_mode"] == true || data["regexp_mode"] == "true"
      start_position = data["start_position"]&.to_i || 0
      end_position = data["end_position"]&.to_i

      if mode == "static"
        # Read the entire file with filter and send all matching lines
        read_static(file_path, filter, regexp_mode, start_position, end_position)
      else
        # Follow the tail of the file indefinitely
        start_log_watcher(file_path, live_tail_position(file_path), filter, regexp_mode)
      end
    end

    def stop_watcher
      cleanup_existing_operations
      transmit({action: "finish", content: "Search stopped."})
    end

    def unsubscribed
      cleanup_existing_operations
    end

    private

    def cleanup_existing_operations
      if @batch_sender
        @batch_sender.stop(send_remaining_lines: false)
        @batch_sender = nil
      end

      stop_log_watcher
    end

    # Bytes from the end of the file to show when starting a live tail without
    # an explicit cursor (matches the default whole-file live-mode page load).
    LIVE_TAIL_BYTES = 10_000

    def live_tail_position(file_path)
      [::File.size(file_path) - LIVE_TAIL_BYTES, 0].max
    end

    def start_log_watcher(file_path, cursor_position, filter = nil, regexp_mode = false)
      return if @log_watcher_running

      @log_watcher_running = true
      @filter = filter
      @regexp_mode = regexp_mode

      transmit({action: "message", content: "Reading file. Please wait..."})

      @log_file = Onlylogs::File.new(file_path, last_position: cursor_position)

      transmit({action: "message", content: ""})

      @log_watcher_thread = Thread.new do
        Rails.logger.silence(Logger::ERROR) do
          current_byte_offset = cursor_position
          @log_file.watch do |new_lines|
            break unless @log_watcher_running

            # Collect all filtered lines from this batch
            lines_to_send = []

            new_lines.each do |log_line|
              # Filters in live mode are not yet implemented
              # if @filter.present? && !Onlylogs::Grep.match_line?(log_line.text, @filter, regexp_mode: @regexp_mode)
              #   next
              # end

              lines_to_send << render_log_line(log_line, byte_offset: current_byte_offset)
              current_byte_offset += log_line.bytesize
            end

            if lines_to_send.any?
              transmit({
                action: "append_logs",
                lines: lines_to_send
              })
            end
          end
        end
      rescue => e
        Rails.logger.error "Log watcher error: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
      ensure
        @log_watcher_running = false
      end
    end

    def stop_log_watcher
      return unless @log_watcher_running

      @log_watcher_running = false

      # Wait for graceful shutdown
      if @log_watcher_thread&.alive?
        @log_watcher_thread.join(3)

        # If still alive after 3 seconds, force kill (but log it)
        if @log_watcher_thread.alive?
          Rails.logger.warn "Onlylogs: Force killing watcher thread after timeout"
          @log_watcher_thread.kill
          @log_watcher_thread.join(1)
        end
      end

      # Clear references to allow GC
      @log_watcher_thread = nil
      @log_file = nil
    end

    def read_static(file_path, filter = nil, regexp_mode = false, start_position = 0, end_position = nil)
      @log_watcher_running = true
      @log_file = Onlylogs::File.new(file_path, last_position: 0)

      transmit({action: "message", content: filter.present? ? "Searching..." : "Loading..."})

      @batch_sender = BatchSender.new(self)
      @batch_sender.start

      begin
        last_line = nil
<<<<<<< HEAD
        line_count = 0

        Rails.logger.silence(Logger::ERROR) do
          is_first_line = true
          reader = ->(log_line) do
            break if @batch_sender.nil? || @log_watcher_running == false

            # Skip first line if start_position > 0 (line is cut off at byte boundary)
            if is_first_line && start_position > 0
              is_first_line = false
              next
            end
            is_first_line = false

            # Buffer previous line and skip it to avoid cut-off lines at boundaries
            if last_line
              @batch_sender.add_line(render_log_line(last_line))
              line_count += 1
            end
            last_line = log_line
          end

          if filter.present?
            @log_file.grep(filter, regexp_mode: regexp_mode, start_position: start_position, end_position: end_position, &reader)
          else
            read_byte_range(file_path, start_position, end_position, &reader)
=======
        last_byte_offset = nil
        line_count = 0

        Rails.logger.silence(Logger::ERROR) do
          if filter.present?
            # Use grep for filtered search
            @log_file.grep(filter, regexp_mode: regexp_mode, start_position: start_position, end_position: end_position) do |result|
              break if @batch_sender.nil? || @log_watcher_running == false

              # Result is a hash with {byte_offset, content}
              byte_offset = result[:byte_offset]
              log_line = result[:content]

              # Skip first and last lines to avoid cut-off lines at boundaries
              if last_line
                @batch_sender.add_line(render_log_line(last_line, byte_offset: last_byte_offset, show_expand_button: true))
                line_count += 1
              end
              last_line = log_line
              last_byte_offset = byte_offset
            end
          else
            # No filter - read all lines directly (skip grep)
            read_byte_range(file_path, start_position, end_position) do |log_line|
              break if @batch_sender.nil? || @log_watcher_running == false

              # Skip first and last lines to avoid cut-off lines at boundaries
              if last_line
                @batch_sender.add_line(render_log_line(last_line, byte_offset: last_byte_offset))
                line_count += 1
              end
              last_line = log_line
              last_byte_offset = nil
            end
>>>>>>> d562515 (Add explore mode to view logs around a specific byte offset)
          end
        end

        # Send last line only if no end_position (avoid cut-off line at byte boundary)
        if last_line && !end_position
<<<<<<< HEAD
          @batch_sender.add_line(render_log_line(last_line))
=======
          @batch_sender.add_line(render_log_line(last_line, byte_offset: last_byte_offset, show_expand_button: filter.present?))
>>>>>>> d562515 (Add explore mode to view logs around a specific byte offset)
          line_count += 1
        end

        @batch_sender.stop

        # Send completion message
        if Onlylogs.max_line_matches && line_count >= Onlylogs.max_line_matches
          transmit({action: "finish", content: "Search finished. Search results limit reached."})
        else
          transmit({action: "finish", content: "Search finished."})
        end
      ensure
        # Always cleanup even if interrupted or error occurs
        @batch_sender&.stop
        @batch_sender = nil
        @log_file = nil
        @log_watcher_running = false
      end
    end

    def read_byte_range(file_path, start_position, end_position)
      file_size = ::File.size(file_path)
      range_size = (end_position || file_size) - start_position

      return if start_position < 0 || range_size <= 0 || start_position >= file_size

      ::File.read(file_path, range_size, start_position).each_line do |line|
        yield line.chomp
      end
    rescue => e
      Rails.logger.error "Error reading byte range: #{e.message}"
    end

<<<<<<< HEAD
    def render_log_line(log_line)
      "<pre>#{FilePathParser.parse(AnsiColorParser.parse(ERB::Util.html_escape(log_line)))}</pre>"
=======
    def render_log_line(log_line, byte_offset: nil, show_expand_button: false)
      parsed = FilePathParser.parse(AnsiColorParser.parse(ERB::Util.html_escape(log_line)))

      {
        content: parsed,
        byte_offset: byte_offset,
        show_expand_button: show_expand_button
      }
>>>>>>> d562515 (Add explore mode to view logs around a specific byte offset)
    end
  end
end
