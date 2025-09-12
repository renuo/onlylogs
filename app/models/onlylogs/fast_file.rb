module Onlylogs
  class Error < StandardError; end

  class FastFile
    CHUNK_SIZE = 1 * 1024 * 1024 # 1MB chunks for reading backwards

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

    def exist?
      ::File.exist?(path)
    end

    def grep(filter, &block)
      Grep.grep(filter, path) do |line_number, content|
        yield Onlylogs::LogLine.new(line_number, content)
      end
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

      lines = lines.map.with_index { |line, index| Onlylogs::LogLine.new(self.last_line_number + index, line) }
      self.last_line_number += lines.length
      lines
    end

    def validate!
      raise Error, "File not found: #{path}" unless exist?
    end

    private

    attr_writer :path, :last_position, :last_line_number

    def last_n_lines_from_snapshot(file, file_size, n)
      need = n
      pos = file_size
      buffer = +""

      # Read backwards in chunks to find the last n lines
      while pos > 0 && need > 0
        step = [ CHUNK_SIZE, pos ].min
        file.seek(pos - step, IO::SEEK_SET)
        chunk = file.read(step)
        buffer.prepend(chunk)
        need -= chunk.count("\n")
        pos -= step
      end

      # Split buffer into lines
      parts = buffer.split("\n", -1)

      # Handle edge case where file ends with newline
      if file_size > 0
        file.seek(file_size - 1, IO::SEEK_SET)
        if file.read(1) == "\n" && parts.last == ""
          parts.pop
        end
      end

      # Return the last n lines
      parts.last(n)
    end

    def calculate_cursor_after_last_line(file, file_size, lines)
      return file_size if lines.empty?

      # Find the position of the last line by reading backwards from the end
      # until we find the start of the last line
      last_line = lines.last
      pos = file_size
      chunk_size = 8192

      # Read backwards in chunks to find where the last line starts
      while pos > 0
        step = [ chunk_size, pos ].min
        file.seek(pos - step, IO::SEEK_SET)
        chunk = file.read(step)

        # Check if the last line starts in this chunk
        if chunk.include?(last_line)
          # Find the exact position where the last line starts
          last_line_start = chunk.rindex(last_line)
          if last_line_start
            # Calculate the absolute position
            absolute_pos = pos - step + last_line_start
            # Cursor should be after the last line (including its newline)
            return absolute_pos + last_line.length + 1
          end
        end

        pos -= step
      end

      # Fallback: if we can't find the exact position, use file size
      file_size
    end
  end
end
