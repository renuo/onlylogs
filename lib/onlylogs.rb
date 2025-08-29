require "onlylogs/version"
require "onlylogs/engine"

# require "zeitwerk"
#
# loader = Zeitwerk::Loader.new
# loader.inflector = Zeitwerk::GemInflector.new(__FILE__)
# loader.push_dir(File.expand_path("..", __dir__))
# loader.setup

module Onlylogs
  mattr_accessor :importmap, default: Importmap::Map.new
end
