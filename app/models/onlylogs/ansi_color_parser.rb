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

    # Pre-compiled regex for better performance
    ANSI_REGEX = /\x1b\[(\d+)m/.freeze

    # Pre-built HTML templates to avoid string interpolation (frozen for better performance)
    HTML_TEMPLATES = {
      "1" => '<span class="fw-bold">'.freeze,
      "30" => '<span class="log-black">'.freeze,
      "31" => '<span class="log-red">'.freeze,
      "32" => '<span class="log-green">'.freeze,
      "33" => '<span class="log-yellow">'.freeze,
      "34" => '<span class="log-blue">'.freeze,
      "35" => '<span class="log-magenta">'.freeze,
      "36" => '<span class="log-cyan">'.freeze,
      "37" => '<span class="log-white">'.freeze,
      "39" => '<span class="">'.freeze,
      "0" => "".freeze # Reset (no color)
    }.freeze

    # Pre-built closing span (frozen for better performance)
    CLOSING_SPAN = "</span>".freeze

    def self.parse(string)
      return string if string.blank?

      # Early return if no ANSI codes present
      return string unless string.include?("\x1b[")

      result = string
      stack = []

      # Replace ANSI color codes with HTML spans
      result = result.gsub(ANSI_REGEX) do |_match|
        code = ::Regexp.last_match(1)

        if code == "0"
          # Reset - close all open spans
          if stack.empty?
            ""
          else
            spans = CLOSING_SPAN * stack.length
            stack.clear
            spans
          end
        elsif (template = HTML_TEMPLATES[code])
          # Add span for this color/attribute
          stack.push(code)
          template
        else
          # Unknown code, ignore
          ""
        end
      end

      # Close any remaining open spans using string multiplication (faster than map/join)
      result += CLOSING_SPAN * stack.length if stack.any?

      result.html_safe
    end
  end
end
