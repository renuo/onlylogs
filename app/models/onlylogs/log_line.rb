# frozen_string_literal: true

module Onlylogs
  class LogLine
    attr_reader :text

    def initialize(text)
      @text = text
    end

    def parsed_text
      FilePathParser.parse(AnsiColorParser.parse(ERB::Util.html_escape(text)))
    end
  end
end
