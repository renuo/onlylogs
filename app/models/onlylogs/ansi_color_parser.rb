# frozen_string_literal: true

module Onlylogs
  class AnsiColorParser
    ANSI_COLORS = {
      "1" => "fw-bold",
      "30" => "log-black",
      "31" => "log-red",
      "32" => "log-green",
      "33" => "log-yellow",
      "34" => "log-blue",
      "35" => "log-magenta",
      "36" => "log-cyan",
      "37" => "log-white",
      "39" => "", # Default foreground color (reset)
      "0" => "" # Reset (no color)
    }.freeze

    def self.parse(string)
      return string if string.blank?

      result = string
      stack = []

      # Replace ANSI color codes with HTML spans
      result = result.gsub(/\x1b\[(\d+)m/) do |_match|
        code = ::Regexp.last_match(1)

        if code == "0"
          # Reset - close all open spans
          spans = stack.map { |_c| "</span>" }.join
          stack.clear
          spans
        elsif ANSI_COLORS[code]
          # Add span for this color/attribute
          stack.push(code)
          "<span class=\"#{ANSI_COLORS[code]}\">"
        else
          # Unknown code, ignore
          ""
        end
      end

      # Close any remaining open spans
      result += stack.map { "</span>" }.join

      result.html_safe
    end
  end
end
