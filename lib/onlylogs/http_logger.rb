# frozen_string_literal: true

require_relative "http_device"
require_relative "multi_device"

# Logs to $stdout (local fallback) and to onlylogs.io (or any Vector-compatible sink) directly via
# HTTP. Unlike SocketLogger it does not require a sidecar process or Puma plugin, so it works from
# any process: Puma, GoodJob, Sidekiq, rake tasks, migrations, etc.
#
# This is a plain Onlylogs::Logger whose log device is an Onlylogs::HttpDevice teed with the local
# fallback. It deliberately does NOT override #add: the stock Logger#add applies the level and
# formats each line before writing, so a below-level line reaches neither sink. All the batching,
# circuit breaking and disk spooling lives in HttpDevice.
module Onlylogs
  class HttpLogger < Onlylogs::Logger
    attr_reader :device

    def initialize(local_fallback: $stdout, **device_options)
      @device = HttpDevice.new(**device_options)
      super(MultiDevice.new(local_fallback, @device))
    end

    # Drain the device's in-memory queue to the drain now (tests and graceful shutdown rely on it).
    def flush
      @device.flush
    end

    # Only the remote device is ours to close; the local fallback ($stdout) belongs to the app, so
    # we deliberately do not call super (which would close the whole log device, fallback included).
    def close
      @device.close
    end
  end
end
