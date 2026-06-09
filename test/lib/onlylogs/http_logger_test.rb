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
            content_length = 0

            while (line = conn.gets)
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

    test "logs locally when no drain URL is configured instead of dropping everything" do
      local = StringIO.new

      logger = capture_stderr do
        Onlylogs::HttpLogger.new(local_fallback: local, drain_url: nil)
      end

      logger.add(Logger::INFO, "local only line")
      logger.close

      assert_includes local.string, "local only line"
    end

    test "reuses a single TCP connection across batches (keep-alive)" do
      server, port, connections = start_keep_alive_server

      logger = Onlylogs::HttpLogger.new(
        drain_url: "http://127.0.0.1:#{port}/drain",
        batch_size: 1,
        flush_interval: 0.05,
        keep_alive_timeout: 30
      )

      logger.add(Logger::INFO, "first batch")
      sleep 0.2
      logger.add(Logger::INFO, "second batch")
      sleep 0.2
      logger.close

      assert_equal 1, connections.value,
        "expected both batches to reuse one keep-alive connection, got #{connections.value}"
    ensure
      logger&.close
      server&.close
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

    # Simulates onlylogs.io being DOWN the way it actually is: the TCP/TLS connection
    # is accepted but the server never sends a response, so each request blocks until the
    # read timeout. This is the dangerous case the unreachable (connection-refused) test
    # above does NOT cover, because connection-refused fails instantly.
    test "bounds the in-memory queue when the drain is down so it cannot OOM the app" do
      hanging_server, hanging_port = start_hanging_server

      logger = Onlylogs::HttpLogger.new(
        drain_url: "http://127.0.0.1:#{hanging_port}/drain",
        batch_size: 100,
        flush_interval: 0.01,
        max_queue_size: 500,
        open_timeout: 0.2,
        read_timeout: 0.2
      )

      # A busy app firing far more lines than a down drain can ever absorb.
      5_000.times { |i| logger.add(Logger::INFO, "line #{i}") }

      queue = logger.instance_variable_get(:@queue)
      assert_operator queue.size, :<=, 500,
        "queue grew past max_queue_size (#{queue.size}); a down drain would exhaust memory"
    ensure
      logger&.close
      hanging_server&.close
    end

    test "stops blocking on every send once the drain is detected as down (circuit breaker)" do
      hanging_server, hanging_port = start_hanging_server

      logger = Onlylogs::HttpLogger.new(
        drain_url: "http://127.0.0.1:#{hanging_port}/drain",
        batch_size: 1,
        flush_interval: 0.01,
        open_timeout: 0.5,
        read_timeout: 0.5
      )

      # Trip the breaker: with batch_size 1, each line is one (failing) send, so logging
      # more than CIRCUIT_FAILURE_THRESHOLD lines produces enough failures to open it.
      5.times { |i| logger.add(Logger::INFO, "trip the breaker #{i}") }
      sleep 2

      # With the breaker open, a flush must return immediately instead of blocking
      # for the full read timeout. This is what keeps request threads from hanging.
      logger.add(Logger::INFO, "after breaker opened")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      logger.flush
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_operator elapsed, :<, 0.2,
        "flush blocked for #{elapsed.round(3)}s; the circuit breaker should make it return instantly"
    ensure
      logger&.close
      hanging_server&.close
    end

    # A failing send must not be reported THROUGH the logger itself: Logger#warn would
    # call back into #add and re-enqueue the error, a self-feeding loop that keeps the
    # queue alive even when the app logs nothing more. Internal errors must go to $stderr.
    test "does not log its own send failures back through itself" do
      hanging_server, hanging_port = start_hanging_server

      local = StringIO.new
      logger = Onlylogs::HttpLogger.new(
        local_fallback: local,
        drain_url: "http://127.0.0.1:#{hanging_port}/drain",
        batch_size: 1,
        flush_interval: 0.01,
        open_timeout: 0.2,
        read_timeout: 0.2
      )

      capture_stderr do
        logger.add(Logger::INFO, "one user line")
        sleep 2
      end

      # The user's line is logged locally; the logger's OWN error must not be (it goes to stderr).
      assert_includes local.string, "one user line"
      refute_includes local.string, "Onlylogs::HttpLogger",
        "the logger logged its own failure through itself, re-entering #add"
    ensure
      logger&.close
      hanging_server&.close
    end

    # After the cooldown elapses the logger retries once; if the drain is still down the
    # circuit must reopen. A regression here silently reverts to a per-send timeout stall.
    test "reopens the circuit after the cooldown while the drain stays down" do
      hanging_server, hanging_port = start_hanging_server

      logger = Onlylogs::HttpLogger.new(
        drain_url: "http://127.0.0.1:#{hanging_port}/drain",
        batch_size: 1,
        flush_interval: 0.01,
        open_timeout: 0.2,
        read_timeout: 0.2,
        circuit_cooldown: 0.6
      )

      capture_stderr do
        5.times { |i| logger.add(Logger::INFO, "open #{i}") }
        open1 = wait_until { logger.instance_variable_get(:@circuit_open_until) }
        assert open1, "circuit should have opened on the initial failures"

        # Let the cooldown lapse, then hand the sender a fresh line to retry.
        sleep 0.7
        logger.add(Logger::INFO, "retry while still down")

        open2 = wait_until do
          later = logger.instance_variable_get(:@circuit_open_until)
          later if later && later > open1
        end
        assert open2, "circuit should reopen after the cooldown when the retry also fails"
      end
    ensure
      logger&.close
      hanging_server&.close
    end

    private

    # Polls the block until it returns a truthy value (returns it) or the timeout elapses.
    def wait_until(timeout: 3)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        result = yield
        return result if result
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.02
      end
    end

    def capture_stderr
      original = $stderr
      $stderr = StringIO.new
      yield
    ensure
      $stderr = original
    end

    # A thread-safe integer the server thread bumps on each accepted connection.
    class Counter
      def initialize
        @mutex = Mutex.new
        @value = 0
      end

      def increment
        @mutex.synchronize { @value += 1 }
      end

      def value
        @mutex.synchronize { @value }
      end
    end

    # Returns [server, port, counter] for an HTTP/1.1 keep-alive server: it serves multiple
    # requests per connection (looping until the client closes) and counts how many distinct
    # TCP connections were accepted, so a test can assert the client reused one.
    def start_keep_alive_server
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      connections = Counter.new

      Thread.new do
        loop do
          client = begin
            server.accept
          rescue
            break
          end
          connections.increment

          Thread.new(client) do |conn|
            loop do
              content_length = 0
              saw_headers = false

              while (line = conn.gets)
                content_length = line.split(": ")[1].to_i if line.start_with?("Content-Length:")
                if line.strip.empty?
                  saw_headers = true
                  break
                end
              end

              break unless saw_headers

              conn.read(content_length) if content_length > 0
              conn.print "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
            end
          ensure
            begin
              conn.close
            rescue
              nil
            end
          end
        end
      end

      [server, port, connections]
    end

    # Returns [server, port] for a server that accepts connections but never replies,
    # forcing clients into a read timeout — mimicking a down onlylogs.io.
    def start_hanging_server
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]

      Thread.new do
        loop do
          client = begin
            server.accept
          rescue
            break
          end
          # Intentionally read and respond nothing: the client will read-timeout.
          @hanging_clients ||= []
          @hanging_clients << client
        end
      end

      [server, port]
    end
  end
end
