# frozen_string_literal: true

module Onlylogs
  class LogLine
    attr_reader :number, :text

    def initialize(number, text)
      @number = number
      @text = text
    end

    def parsed_number
      number.to_s.reverse.gsub(/(\d{3})(?=\d)/, "\\1'").reverse.rjust(7)
    end

    def parsed_text
      AnsiColorParser.parse(FilePathParser.parse(text))
    end

    def to_a
      [number, text]
    end
  end
end
