module Onlylogs
  class Grep
    def self.grep(pattern, file_path, start_position: 0, end_position: 100, &block)
      # Use the appropriate script based on configuration
      script_name = Onlylogs.grep_command == :rg ? "super_ripgrep" : "super_grep"
      super_grep_path = ::File.expand_path("../../../bin/#{script_name}", __dir__)
      results = []

      IO.popen("#{super_grep_path} \"#{pattern}\" \"#{file_path}\" 2>/dev/null") do |io|
        io.each_line do |line|
          # Parse each line as it comes in - super_grep returns grep output with line numbers (format: line_number:content)
          if match = line.strip.match(/^(\d+):(.*)/)
            line_number = match[1].to_i
            content = match[2]

            if block_given?
              yield line_number, content
            else
              results << [ line_number, content ]
            end
          end
        end
      end

      block_given? ? nil : results
    end

    def self.match_line?(line, string)
      # Strip ANSI color codes from the line before matching
      stripped_line = line.gsub(/\e\[[0-9;]*m/, "")
      # Normalize multiple spaces to single spaces
      normalized_line = stripped_line.gsub(/\s+/, " ")
      normalized_line.match?(Regexp.escape(string))
    end

    def self.using_grep?
      Onlylogs.grep_command == :grep
    end
  end
end
