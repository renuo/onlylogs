module Onlylogs
  class Error < StandardError; end

  class File
    attr_reader :path, :last_position, :last_line_number

    def initialize(path, last_position: 0)
      self.path = path
      self.last_position = last_position
      self.last_line_number = 0
      validate!
    end

    def go_to_position(position)
      return if position < 0

      self.last_position = position
      self.last_line_number = 0
    end

    def watch(&block)
      # return enum_for(:watch) unless block

      loop do
        sleep 0.5

        new_lines = read_new_lines
        next if new_lines.empty?

        yield new_lines
      end
    end

    def size
      ::File.size(path)
    end

    def exist?
      ::File.exist?(path)
    end

    def text_file?
      self.class.text_file?(path)
    end

    def self.text_file?(path)
      return false unless ::File.exist?(path)
      return false if ::File.zero?(path)

      # Read first chunk and check for null bytes (binary indicator)
      ::File.open(path, "rb") do |file|
        chunk = file.read(8192) || ""
        # If it contains null bytes, it's likely binary
        return false if chunk.include?("\x00")
      end

      true
    end

    def grep(filter, regexp_mode: false, start_position: 0, end_position: nil, &block)
      Grep.grep(filter, path, regexp_mode: regexp_mode, start_position: start_position, end_position: end_position) do |line_number, content|
        yield Onlylogs::LogLine.new(line_number, content)
      end
    end

    private

    attr_writer :path, :last_position, :last_line_number

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

      lines = lines.map.with_index { |line, index| Onlylogs::LogLine.new(self.last_line_number + index, line) }
      self.last_line_number += lines.length
      lines
    end

    def validate!
      raise Error, "File not found: #{path}" unless exist?
    end
  end
end
