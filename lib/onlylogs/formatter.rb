module Onlylogs
  class Formatter < ActiveSupport::Logger::SimpleFormatter
    include ActiveSupport::TaggedLogging::Formatter

    attr_accessor :denylist

    def initialize
      super
      @denylist = []
    end

    def call(severity, time, progname, msg)
      text = msg2str(msg)
      return nil if text.include?("Onlylogs::LogsChannel")
      return nil if denylist.any? { |pattern| pattern.match?(text) }
      tags = [time.iso8601, severity[0].upcase]
      push_tags tags
      str = super(severity, time, progname, text)
      pop_tags tags.size
      str
    end
  end
end
