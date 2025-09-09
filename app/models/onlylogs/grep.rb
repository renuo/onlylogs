module Onlylogs
  class Grep
    # a grep on a whole file, uses grep under the hood, to have a fast search
    def self.grep(pattern, file_path, start_position: 0, end_position: 100)
      # Use the super_grep script to handle ANSI color codes
      super_grep_path = ::File.expand_path("../../../bin/super_grep", __dir__)

      # Execute the super_grep script and suppress the "grepping for..." message
      result = `#{super_grep_path} "#{pattern}" "#{file_path}" 2>/dev/null`

      # Parse the result - super_grep returns grep output with line numbers (format: line_number:content)
      lines = result.strip.split("\n")

      # Parse all matching lines and return them in the format [[line_number, content], ...]
      lines.map do |line|
        if match = line.match(/^(\d+):(.*)/)
          line_number = match[1].to_i
          content = match[2]
          [ line_number, content ]
        end
      end.compact
    end

    def self.match_line?(line, string)
      line.match?(Regexp.escape(string))
    end
  end
end
