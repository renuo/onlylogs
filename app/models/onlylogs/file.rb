module Onlylogs
  class Error < StandardError; end

  class File
    attr_reader :path, :last_position

    def initialize(path, last_position: 0)
      self.path = path
      self.last_position = last_position
      validate!
    end

    def go_to_position(position)
      return if position < 0

      self.last_position = position
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
      Grep.grep(filter, path, regexp_mode: regexp_mode, start_position: start_position, end_position: end_position) do |content|
        yield content
      end
    end

    private

    attr_writer :path, :last_position

    def read_new_lines
      return [] unless exist?

      current_size = ::File.size(path)
      return [] if current_size <= last_position

      lines = []

      ::File.open(path, "rb") do |file|
        file.seek(last_position)

        # Skip first line if we're mid-line (not at start or after newline)
        if last_position > 0
          file.seek(last_position - 1)
          skip_first = (file.read(1) != "\n")
          file.seek(last_position)
          file.gets if skip_first # Consume incomplete line
        end

        # Read complete lines using gets (memory efficient, no buffer needed)
        while (line = file.gets)
          if line.end_with?("\n")
            # Complete line - store as simple string
            lines << line.chomp
            self.last_position = file.pos
          else
            # Incomplete line at EOF - skip it
            break
          end
        end
      end

      lines
    end

    def validate!
      raise Error, "File not found: #{path}" unless exist?
    end
  end
end
