# frozen_string_literal: true

require "socket"

# This logger sends messages to onlylogs.io via a UNIX socket connected to the onlylogs sidecar process.
# You need to have the onlylogs sidecar running for this to work.

module Onlylogs
  class SocketLogger < Onlylogs::Logger
    DEFAULT_SOCKET = "tmp/sockets/onlylogs-sidecar.sock"

    def initialize(local_fallback: $stdout, socket_path: ENV.fetch("ONLYLOGS_SIDECAR_SOCKET", DEFAULT_SOCKET))
      super(local_fallback)
      @socket_path = socket_path
      @socket_mutex = Mutex.new
      @socket = nil
    end

    def add(severity, message = nil, progname = nil, &block)
      if message.nil?
        if block_given?
          message = block.call
        else
          message = progname
          progname = nil
        end
      end

      formatted = format_message(format_severity(severity), Time.now, progname, message.to_s)
      send_to_socket(formatted)
      super
    end

    private

    def send_to_socket(payload)
      return if payload.nil? || payload.empty?

      socket = ensure_socket
      socket&.puts(payload)
    rescue Errno::EPIPE, Errno::ECONNREFUSED, Errno::ENOENT => e
      $stderr.puts "Onlylogs::SocketLogger error: #{e.message}" # rubocop:disable Style/StderrPuts
      reconnect_socket
    rescue => e
      $stderr.puts "Onlylogs::SocketLogger unexpected error: #{e.class}: #{e.message}" # rubocop:disable Style/StderrPuts
      reconnect_socket
    end

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
