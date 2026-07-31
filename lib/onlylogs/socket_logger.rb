# frozen_string_literal: true

require_relative "socket_device"
require_relative "multi_device"

# Logs to $stdout (local fallback) and to onlylogs.io via a UNIX socket connected to the onlylogs
# sidecar process. You need to have the onlylogs sidecar running for the socket sink to work.
#
# This is a plain Onlylogs::Logger whose log device is the sidecar socket teed with the local
# fallback. It deliberately does NOT override #add: the stock Logger#add applies the level and
# formats each line before writing, so a below-level line reaches neither sink.
module Onlylogs
  class SocketLogger < Onlylogs::Logger
    attr_reader :device

    def initialize(local_fallback: $stdout, socket_path: ENV.fetch("ONLYLOGS_SIDECAR_SOCKET", SocketDevice::DEFAULT_SOCKET))
      @device = SocketDevice.new(socket_path: socket_path)
      super(MultiDevice.new(local_fallback, @device))
    end

    # Only the remote socket is ours to close; the local fallback ($stdout) belongs to the app, so
    # we deliberately do not call super (which would close the whole log device, fallback included).
    def close
      @device.close
    end
  end
end
