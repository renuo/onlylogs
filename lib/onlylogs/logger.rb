module Onlylogs
  class Logger < ActiveSupport::Logger
    include ActiveSupport::TaggedLogging

    def initialize(*args)
      super
      self.formatter = Onlylogs::Formatter.new
    end
  end
end
