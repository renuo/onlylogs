# frozen_string_literal: true

module Onlylogs
  # A Logger log device that fans each line out to several underlying devices, e.g. the local
  # $stdout fallback plus a remote sink (Onlylogs::SocketDevice / Onlylogs::HttpDevice).
  class MultiDevice
    def initialize(*devices)
      @devices = devices.compact
    end

    def write(message)
      return if message.nil? || message.empty?

      @devices.each { |device| device.write(message) }
    end

    def close
      @devices.each do |device|
        # Never close the process' standard streams — the app owns them, not us.
        next if device.equal?($stdout) || device.equal?($stderr)

        device.close if device.respond_to?(:close)
      end
    end

    def flush
      @devices.each { |device| device.flush if device.respond_to?(:flush) }
    end
  end
end
