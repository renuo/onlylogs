require "onlylogs/version"
require "onlylogs/configuration"
require "onlylogs/engine"
require "onlylogs/formatter"
require "onlylogs/logger"
require "onlylogs/spool"
require "onlylogs/multi_device"
require "onlylogs/socket_device"
require "onlylogs/http_device"
require "onlylogs/socket_logger"
require "onlylogs/http_logger"

# require "zeitwerk"
#
# loader = Zeitwerk::Loader.new
# loader.inflector = Zeitwerk::GemInflector.new(__FILE__)
# loader.push_dir(File.expand_path("..", __dir__))
# loader.setup

module Onlylogs
  # Defined here rather than in an autoloaded file: these are referenced from
  # class bodies (rescue_from, subclassing), which Zeitwerk cannot resolve
  # without a matching file of its own.
  class Error < StandardError; end

  class ForbiddenPathError < StandardError; end

  if defined?(Importmap)
    mattr_accessor :importmap, default: Importmap::Map.new
  end
end
