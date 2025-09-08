module Onlylogs
  class Error < StandardError; end

  class File
    attr_reader :path, :last_position, :last_line_number

    def self.stream_channel
      "Onlylogs::LogsChannel"
    end

    def initialize(path, last_position: 0)
      self.path = path
      self.last_position = last_position
      validate!
      calculate_line_number!
      Rails.logger.info "Initialized Onlylogs::File for #{path} at position #{last_position}, line #{@last_line_number}"
    end

    def go_to_position(position)
      return if position < 0

      self.last_position = position
      calculate_line_number!
    end

    def watch(&block)
      # return enum_for(:watch) unless block

      loop do
        new_lines = read_new_lines
        next if new_lines.empty?

        yield new_lines

        sleep 0.5
      end
    end

    def size
      ::File.size(path)
    end

    def exist?
      ::File.exist?(path)
    end

    private

    attr_writer :path, :last_position

    def calculate_line_number!
      @last_line_number = `head -c "#{last_position}" #{path} | wc -l`.strip.to_i
    end

    def read_new_lines
      return [] unless exist?

      current_size = ::File.size(path)
      return [] if current_size <= last_position

      # Read new content from last_position to end of file
      new_content = ""
      ::File.open(path, "rb") do |file|
        file.seek(last_position)
        new_content = file.read
      end

      return [] if new_content.empty?

      # Split into lines, handling incomplete lines
      lines = new_content.lines(chomp: true)

      # If we're not at the beginning of the file, check if we're at a line boundary
      first_line_removed = false
      if last_position > 0
        # Read one character before to see if it was a newline
        ::File.open(path, "rb") do |file|
          file.seek(last_position - 1)
          char_before = file.read(1)
          # If the character before wasn't a newline, we're in the middle of a line
          if char_before != "\n" && lines.any?
            # Remove the first line as it's incomplete
            lines.shift
            first_line_removed = true
          end
        end
      end

      # Check if the last line is complete (ends with newline)
      last_line_incomplete = lines.any? && !new_content.end_with?("\n")
      if last_line_incomplete
        # Remove the last line as it's incomplete
        lines.pop
      end

      # Update position to end of last complete line
      if lines.any?
        # Find the position after the last complete line
        ::File.open(path, "rb") do |file|
          file.seek(last_position)
          # Read and count newlines to find where complete lines end
          newline_count = 0
          # If we removed the first line, we need to count one extra newline
          # to account for the incomplete first line
          target_newlines = lines.length + (first_line_removed ? 1 : 0)
          while newline_count < target_newlines
            char = file.read(1)
            break unless char

            newline_count += 1 if char == "\n"
          end
          self.last_position = file.tell
        end
      elsif last_line_incomplete
        # If we had lines but removed the last incomplete one,
        # position should be at the start of the incomplete line
        self.last_position = current_size - new_content.lines.last.length
      elsif first_line_removed
        # If we removed the first line but have no complete lines,
        # position should be at the end of the file since we consumed all content
        self.last_position = current_size
      else
        # No lines at all, position at end of file
        self.last_position = current_size
      end

      # Calculate line numbers for the new lines
      # @last_line_number represents the last complete line we've read
      # So the next line to read is @last_line_number + 1
      starting_line_number = @last_line_number + 1
      @last_line_number += lines.length

      # Return lines with correct line numbers
      lines.map.with_index { |line, index| Onlylogs::LogLine.new(starting_line_number + index, line) }
    end

    def validate!
      raise Error, "File not found: #{path}" unless exist?
    end
  end
end
