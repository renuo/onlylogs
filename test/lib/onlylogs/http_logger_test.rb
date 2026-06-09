# frozen_string_literal: true

require "test_helper"
require "socket"

module Onlylogs
  class HttpLoggerTest < ActiveSupport::TestCase
    setup do
      @drains = []
      @loggers = []
    end

    teardown do
      @loggers.each do |logger|
        logger.close
      rescue
        nil
      end
      @drains.each(&:close)
    end

    test "batches and sends log lines to the drain URL" do
      drain = build_drain
      logger = build_logger(drain, batch_size: 2, flush_interval: 10)

      logger.add(Logger::INFO, "first line")
      logger.add(Logger::INFO, "second line")

      sleep 0.2
      logger.close

      assert_includes drain.received, "first line"
      assert_includes drain.received, "second line"
    end

    test "flushes on interval when batch size is not reached" do
      drain = build_drain
      logger = build_logger(drain, batch_size: 1000, flush_interval: 0.1)

      logger.add(Logger::INFO, "interval flush line")

      sleep 0.3
      logger.close

      assert_includes drain.received, "interval flush line"
    end

    test "logs locally when no drain URL is configured instead of dropping everything" do
      local = StringIO.new

      logger = capture_stderr do
        build_logger(nil, local_fallback: local)
      end

      logger.add(Logger::INFO, "local only line")
      logger.close

      assert_includes local.string, "local only line"
    end

    test "reuses a single TCP connection across batches (keep-alive)" do
      drain = build_drain
      logger = build_logger(drain, batch_size: 1, flush_interval: 0.05, keep_alive_timeout: 30)

      logger.add(Logger::INFO, "first batch")
      sleep 0.2
      logger.add(Logger::INFO, "second batch")
      sleep 0.2
      logger.close

      assert_equal 1, drain.connection_count,
        "expected both batches to reuse one keep-alive connection, got #{drain.connection_count}"
    end

    test "does not crash when drain URL is unreachable" do
      logger = build_logger("http://127.0.0.1:1/drain", flush_interval: 0.05)

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
      drain = build_drain(status: :hang)
      logger = build_logger(drain,
        batch_size: 100, flush_interval: 0.01, max_queue_size: 500, open_timeout: 0.2, read_timeout: 0.2)

      # A busy app firing far more lines than a down drain can ever absorb.
      5_000.times { |i| logger.add(Logger::INFO, "line #{i}") }

      queue = logger.instance_variable_get(:@queue)
      assert_operator queue.size, :<=, 500,
        "queue grew past max_queue_size (#{queue.size}); a down drain would exhaust memory"
    end

    test "stops blocking on every send once the drain is detected as down (circuit breaker)" do
      drain = build_drain(status: :hang)
      logger = build_logger(drain, batch_size: 1, flush_interval: 0.01, open_timeout: 0.5, read_timeout: 0.5)

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
    end

    # A failing send must not be reported THROUGH the logger itself: Logger#warn would
    # call back into #add and re-enqueue the error, a self-feeding loop that keeps the
    # queue alive even when the app logs nothing more. Internal errors must go to $stderr.
    test "does not log its own send failures back through itself" do
      drain = build_drain(status: :hang)
      local = StringIO.new
      logger = build_logger(drain,
        local_fallback: local, batch_size: 1, flush_interval: 0.01, open_timeout: 0.2, read_timeout: 0.2)

      capture_stderr do
        logger.add(Logger::INFO, "one user line")
        sleep 2
      end

      # The user's line is logged locally; the logger's OWN error must not be (it goes to stderr).
      assert_includes local.string, "one user line"
      refute_includes local.string, "Onlylogs::HttpLogger",
        "the logger logged its own failure through itself, re-entering #add"
    end

    # A drain that is UP but answers a non-2xx status must be treated as a failed delivery.
    # Net::HTTP does not raise on 4xx/5xx, so without an explicit status check every 503 would
    # look like a success: the batch would be silently dropped and the circuit would never open.
    test "treats a non-2xx drain response as a failure and opens the circuit" do
      drain = build_drain(status: 503)
      logger = build_logger(drain, batch_size: 1, flush_interval: 0.01)

      capture_stderr do
        5.times { |i| logger.add(Logger::INFO, "error response #{i}") }
        opened = wait_until { logger.instance_variable_get(:@circuit_open_until) }
        assert opened, "a 5xx drain response should count as a failure and open the circuit"
      end
    end

    # A drain URL without a path (e.g. "https://onlylogs.io") must still deliver. Net::HTTP::Post.new("")
    # raises "HTTP request path is empty", so without defaulting the path to "/" every send would fail
    # and the circuit would open permanently — buffering every batch to the spool forever.
    test "delivers to a drain URL that has no path" do
      drain = build_drain
      logger = build_logger(drain.url(""), batch_size: 1, flush_interval: 0.01, spool_dir: "")

      logger.add(Logger::INFO, "pathless drain line")

      assert wait_until { drain.received.include?("pathless drain line") },
        "a drain URL without a path should default to / and deliver"
    end

    # After the cooldown elapses the logger retries once; if the drain is still down the
    # circuit must reopen. A regression here silently reverts to a per-send timeout stall.
    test "reopens the circuit after the cooldown while the drain stays down" do
      drain = build_drain(status: :hang)
      logger = build_logger(drain,
        batch_size: 1, flush_interval: 0.01, open_timeout: 0.2, read_timeout: 0.2, circuit_cooldown: 0.6)

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
    end

    private

    # Spins up a MockDrain and registers it so teardown closes it. See MockDrain for `status:`.
    def build_drain(**opts)
      MockDrain.new(**opts).tap { |drain| @drains << drain }
    end

    # Builds an HttpLogger pointed at the given target (a MockDrain, a raw URL string, or nil for
    # the no-drain case) and registers it so teardown closes it.
    def build_logger(target, **opts)
      url = target.is_a?(MockDrain) ? target.url : target
      Onlylogs::HttpLogger.new(drain_url: url, **opts).tap { |logger| @loggers << logger }
    end

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
  end
end
