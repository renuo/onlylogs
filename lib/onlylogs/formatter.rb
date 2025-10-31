module Onlylogs
  class Formatter < ActiveSupport::Logger::SimpleFormatter
    include ActiveSupport::TaggedLogging::Formatter

    def call(severity, time, progname, msg)
      return nil if "Onlylogs::LogsChannel".in?(msg)
      tags = [ time.iso8601, severity[0].upcase ]
      push_tags tags
      str = super
      pop_tags tags.size
      str
    end
  end
end
