module Onlylogs
  class Grep
    def self.grep(pattern, file_path, start_position: 0, end_position: nil, regexp_mode: false, &block)
      # Use the appropriate script based on configuration
      script_name = Onlylogs.ripgrep_enabled? ? "super_ripgrep" : "super_grep"
      super_grep_path = ::File.expand_path("../../../bin/#{script_name}", __dir__)

      command_args = [super_grep_path]
      command_args += ["--max-matches", Onlylogs.max_line_matches.to_s] if Onlylogs.max_line_matches.present?
      command_args << "--regexp" if regexp_mode

      # Add byte range parameters if specified
      if start_position > 0 || end_position
        command_args << "--start-position" << start_position.to_s
        command_args << "--end-position" << end_position.to_s if end_position
      end

      command_args += [pattern, file_path]

      results = []

      # Set up parsing logic based on whether ripgrep includes byte offsets
      parse_line = if Onlylogs.ripgrep_enabled?
        ->(line) {
          parts = line.split(":", 2)
          [parts[0].to_i, parts[1] || ""]
        }
      else
        ->(line) { [nil, line] }
      end

      IO.popen(command_args, err: "/dev/null") do |io|
        io.each_line do |line|
          byte_offset, content = parse_line.call(line.chomp)

          # Use String.new to create a copy and prevent memory retention from IO buffers
          content = String.new(content, encoding: Encoding::UTF_8).scrub

          result = {byte_offset: byte_offset, content: content}

          if block_given?
            yield result
          else
            results << result
          end
        end
      end

      block_given? ? nil : results
    end

    def self.match_line?(line, string, regexp_mode: false)
      # Strip ANSI color codes from the line before matching
      stripped_line = line.gsub(/\e\[[0-9;]*m/, "")
      # Normalize multiple spaces to single spaces
      normalized_line = stripped_line.gsub(/\s+/, " ")

      if regexp_mode
        normalized_line.match?(string)
      else
        normalized_line.match?(Regexp.escape(string))
      end
    end
  end
end
