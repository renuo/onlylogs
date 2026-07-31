# frozen_string_literal: true

require "socket"

module Onlylogs
  # Send failures are reported to $stderr — never through a logger — so a failing socket can never
  # re-enter logging and deadlock or loop.
  class SocketDevice
    DEFAULT_SOCKET = "tmp/sockets/onlylogs-sidecar.sock"

    def initialize(socket_path: ENV.fetch("ONLYLOGS_SIDECAR_SOCKET", DEFAULT_SOCKET))
      @socket_path = socket_path
      @socket_mutex = Mutex.new
      @socket = nil
    end

    def write(message)
      return if message.nil? || message.empty?

      socket = ensure_socket
      socket&.puts(message)
    rescue Errno::EPIPE, Errno::ECONNREFUSED, Errno::ENOENT => e
      $stderr.puts "Onlylogs::SocketDevice error: #{e.message}" # rubocop:disable Style/StderrPuts
      reconnect_socket
    rescue => e
      $stderr.puts "Onlylogs::SocketDevice unexpected error: #{e.class}: #{e.message}" # rubocop:disable Style/StderrPuts
      reconnect_socket
    end

    def close
      reconnect_socket
    end

    private

    def ensure_socket
      return @socket if @socket

      @socket_mutex.synchronize do
        @socket ||= UNIXSocket.new(@socket_path)
      rescue => e
        $stderr.puts "Unable to connect to Onlylogs sidecar (#{@socket_path}): #{e.message}" # rubocop:disable Style/StderrPuts
        @socket = nil
      end

      @socket
    end

    def reconnect_socket
      @socket_mutex.synchronize do
        begin
          @socket&.close
        rescue
          nil
        end
        @socket = nil
      end
    end
  end
end
