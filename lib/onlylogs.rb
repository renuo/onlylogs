require "onlylogs/version"
require "onlylogs/log_silencer_middleware"
require "onlylogs/configuration"
require "onlylogs/engine"
require "onlylogs/formatter"
require "onlylogs/logger"
require "onlylogs/socket_logger"

# require "zeitwerk"
#
# loader = Zeitwerk::Loader.new
# loader.inflector = Zeitwerk::GemInflector.new(__FILE__)
# loader.push_dir(File.expand_path("..", __dir__))
# loader.setup

module Onlylogs
  mattr_accessor :importmap, default: Importmap::Map.new
end
