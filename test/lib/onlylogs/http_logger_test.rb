# frozen_string_literal: true

require "test_helper"
require "socket"

module Onlylogs
  class HttpLoggerTest < ActiveSupport::TestCase
    setup do
      @received_bodies = []
      @mutex = Mutex.new

      @port = 9999
      @server = TCPServer.new("127.0.0.1", @port)

      @server_thread = Thread.new do
        loop do
          client = begin
            @server.accept
          rescue
            break
          end
          Thread.new(client) do |conn|
            request = ""
            content_length = 0

            while (line = conn.gets)
              request += line
              content_length = line.split(": ")[1].to_i if line.start_with?("Content-Length:")
              break if line.strip.empty?
            end

            body = conn.read(content_length) if content_length > 0
            @mutex.synchronize { @received_bodies << body } if body

            conn.print "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
            conn.close
          end
        end
      end
    end

    teardown do
      @server&.close
      @server_thread&.join(1)
    end

    test "batches and sends log lines to the drain URL" do
      logger = Onlylogs::HttpLogger.new(
        drain_url: "http://127.0.0.1:#{@port}/drain",
        batch_size: 2,
        flush_interval: 10
      )

      logger.add(Logger::INFO, "first line")
      logger.add(Logger::INFO, "second line")

      sleep 0.2
      logger.close

      bodies = @mutex.synchronize { @received_bodies.dup }
      combined = bodies.join("\n")

      assert_includes combined, "first line"
      assert_includes combined, "second line"
    end

    test "flushes on interval when batch size is not reached" do
      logger = Onlylogs::HttpLogger.new(
        drain_url: "http://127.0.0.1:#{@port}/drain",
        batch_size: 1000,
        flush_interval: 0.1
      )

      logger.add(Logger::INFO, "interval flush line")

      sleep 0.3
      logger.close

      bodies = @mutex.synchronize { @received_bodies.dup }
      combined = bodies.join("\n")

      assert_includes combined, "interval flush line"
    end

    test "does not crash when drain URL is unreachable" do
      logger = Onlylogs::HttpLogger.new(
        drain_url: "http://127.0.0.1:1/drain",
        flush_interval: 0.05
      )

      assert_nothing_raised do
        logger.add(Logger::INFO, "unreachable test")
        sleep 0.2
        logger.close
      end
    end
  end
end
