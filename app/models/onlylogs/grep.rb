module Onlylogs
  class Grep
    # a grep on a whole file, uses grep under the hood, to have a fast search
    def self.grep(pattern, file_path, start_position: 0, end_position: 100, &block)
      # Use the super_grep script to handle ANSI color codes
      super_grep_path = ::File.expand_path("../../../bin/super_grep", __dir__)

      if block_given?
        # Stream mode: process each line immediately without storing
        IO.popen("#{super_grep_path} \"#{pattern}\" \"#{file_path}\" 2>/dev/null") do |io|
          io.each_line do |line|
            # Parse each line as it comes in - super_grep returns grep output with line numbers (format: line_number:content)
            if match = line.strip.match(/^(\d+):(.*)/)
              line_number = match[1].to_i
              content = match[2]
              yield line_number, content
            end
          end
        end
        nil
      else
        # Collect mode: store all results in an array
        results = []
        IO.popen("#{super_grep_path} \"#{pattern}\" \"#{file_path}\" 2>/dev/null") do |io|
          io.each_line do |line|
            # Parse each line as it comes in - super_grep returns grep output with line numbers (format: line_number:content)
            if match = line.strip.match(/^(\d+):(.*)/)
              line_number = match[1].to_i
              content = match[2]
              results << [ line_number, content ]
            end
          end
        end
        results
      end
    end

    def self.match_line?(line, string)
      line.match?(Regexp.escape(string))
    end
  end
end
