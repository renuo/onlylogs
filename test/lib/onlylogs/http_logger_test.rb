# frozen_string_literal: true

require "test_helper"
require "socket"
require "tmpdir"
require "fileutils"

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
    test "bounds the in-memory queue by bytes when the drain is down so it cannot OOM the app" do
      drain = build_drain(status: :hang)
      logger = build_logger(drain,
        batch_size: 100, flush_interval: 0.01, max_queue_bytes: 50_000, open_timeout: 0.2, read_timeout: 0.2)

      # A busy app logging payloads far faster than a down drain can ever absorb.
      payload = "x" * 1_000
      5_000.times { |i| logger.add(Logger::INFO, "line #{i} #{payload}") }

      device = logger.device
      queued_bytes = device.instance_variable_get(:@queued_bytes)
      assert_operator queued_bytes, :<=, 50_000,
        "queue grew to #{queued_bytes} bytes, past max_queue_bytes; a down drain would exhaust memory"
      assert_operator device.instance_variable_get(:@dropped), :>, 0
    end

    test "releases queued bytes once the sender has shipped the lines" do
      drain = build_drain
      logger = build_logger(drain, batch_size: 1000, flush_interval: 0.05)

      10.times { |i| logger.add(Logger::INFO, "shipped line #{i}") }

      device = logger.device
      assert wait_until { drain.received.include?("shipped line 9") }
      assert wait_until { device.instance_variable_get(:@queued_bytes).zero? },
        "queued bytes ledger did not return to 0 after the queue was drained"
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

      # The user's line is logged locally; the device's OWN error must not be (it goes to stderr).
      assert_includes local.string, "one user line"
      refute_includes local.string, "Onlylogs::HttpDevice",
        "the device logged its own failure through the logger, re-entering #add"
    end

    # A drain that is UP but answers a non-2xx status must be treated as a failed delivery.
    # Net::HTTP does not raise on 4xx/5xx, so without an explicit status check every 503 would
    # look like a success: the batch would be silently dropped and the circuit would never open.
    test "treats a non-2xx drain response as a failure and opens the circuit" do
      drain = build_drain(status: 503)
      logger = build_logger(drain, batch_size: 1, flush_interval: 0.01)

      capture_stderr do
        5.times { |i| logger.add(Logger::INFO, "error response #{i}") }
        opened = wait_until { logger.device.instance_variable_get(:@circuit_open_until) }
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
        open1 = wait_until { logger.device.instance_variable_get(:@circuit_open_until) }
        assert open1, "circuit should have opened on the initial failures"

        # Keep handing the sender lines: the pause is jittered, so the retry happens sometime
        # between 0.5x and 1.5x the cooldown, and without a spool only a live batch triggers it.
        open2 = wait_until do
          logger.add(Logger::INFO, "retry while still down")
          later = logger.device.instance_variable_get(:@circuit_open_until)
          later if later && later > open1
        end
        assert open2, "circuit should reopen after the cooldown when the retry also fails"
      end
    end

    # With a spool configured, a failing drain must not lose data: batches are buffered to disk
    # while it is down and replayed once it recovers.
    test "buffers batches to disk while the drain is failing, then replays them on recovery" do
      dir = ::Dir.mktmpdir
      drain = build_drain(status: 503)
      logger = build_logger(drain, batch_size: 1, flush_interval: 0.01, circuit_cooldown: 0.3, spool_dir: dir)

      capture_stderr do
        3.times { |i| logger.add(Logger::INFO, "buffered #{i}") }

        # Wait until the circuit has tripped: that guarantees all three sends failed and were
        # buffered, so the drain flip below cannot race with a still-in-flight batch.
        assert wait_until { logger.device.instance_variable_get(:@circuit_open_until) },
          "the failing drain should buffer batches and trip the circuit"
        refute_empty ::Dir.glob(::File.join(dir, "*.batch")),
          "the failed batches should be on disk in the spool"

        # Drain recovers; once the cooldown lapses the next successful send replays the backlog.
        drain.status = 200
        sleep 0.4
        logger.add(Logger::INFO, "recovery trigger")

        assert wait_until { ::Dir.glob(::File.join(dir, "*.batch")).empty? },
          "the spool should drain once the drain recovers"
      end

      assert_includes drain.received, "buffered 0"
      assert_includes drain.received, "buffered 2"
      assert_includes drain.received, "recovery trigger"
    ensure
      logger&.close
      ::FileUtils.remove_entry(dir) if dir && ::File.directory?(dir)
    end

    # The spool survives a process restart: a new logger picks up files a previous run left behind.
    test "replays batches left in the spool by a previous run (survives restart)" do
      dir = ::Dir.mktmpdir
      previous = Onlylogs::Spool.new(dir: dir)
      previous.write("orphaned one")
      previous.write("orphaned two")

      drain = build_drain(status: 200)
      logger = build_logger(drain, batch_size: 1, flush_interval: 0.01, spool_dir: dir)

      assert wait_until { ::Dir.glob(::File.join(dir, "*.batch")).empty? },
        "a new logger should replay spool files left by a previous run"

      assert_includes drain.received, "orphaned one"
      assert_includes drain.received, "orphaned two"
    ensure
      logger&.close
      ::FileUtils.remove_entry(dir) if dir && ::File.directory?(dir)
    end

    # The spool is opt-out: enabled by default, disabled by an empty ONLYLOGS_SPOOL_DIR.
    test "enables the disk spool by default and lets an empty dir opt out" do
      drain = build_drain(status: 200)

      default_logger = Onlylogs::HttpLogger.new(drain_url: drain.url)
      @loggers << default_logger
      spool = default_logger.device.instance_variable_get(:@spool)
      assert spool, "the spool should be enabled by default"

      disabled = Onlylogs::HttpLogger.new(drain_url: drain.url, spool_dir: "")
      @loggers << disabled
      assert_nil disabled.device.instance_variable_get(:@spool),
        "an empty spool dir should opt out of buffering"
    ensure
      spool_dir = spool&.instance_variable_get(:@dir)
      ::FileUtils.remove_entry(spool_dir) if spool_dir && ::File.directory?(spool_dir)
    end

    # The logger's level must gate the remote drain, not only the local $stdout fallback.
    # #add ships to the drain before delegating to super (which is where ::Logger#add checks
    # the level), so without an explicit guard every DEBUG line reaches onlylogs.io even at
    # level INFO — e.g. Sentry's `[Transport]`/`[Tracing]` debug chatter in a production app.
    test "does not send lines below the configured level to the drain" do
      drain = build_drain
      logger = build_logger(drain, batch_size: 1, flush_interval: 0.01)
      logger.level = Logger::INFO

      logger.add(Logger::DEBUG, "debug below threshold")
      logger.add(Logger::INFO, "info above threshold")

      assert wait_until { drain.received.include?("info above threshold") }
      refute_includes drain.received, "debug below threshold",
        "a DEBUG line was shipped to the drain even though the level is INFO"
    end

    # Puma cluster mode (and fork_worker) builds the logger in the master and forks the workers;
    # threads are not inherited, so without supervision every worker logs into a queue nobody reads.
    test "ships lines logged in a forked child, which does not inherit the sender thread" do
      skip "fork is not available" unless Process.respond_to?(:fork)

      drain = build_drain
      logger = build_logger(drain, batch_size: 1, flush_interval: 0.01)

      logger.add(Logger::INFO, "parent line")
      assert wait_until { drain.received.include?("parent line") }

      # exit! skips at_exit, which would otherwise run minitest itself again in the child.
      pid = fork do
        logger.add(Logger::INFO, "child line")
        logger.close
        exit!(0)
      end
      Process.wait(pid)

      assert wait_until { drain.received.include?("child line") },
        "the child's line never reached the drain: the sender thread did not survive the fork"
    end

    # Workers share one spool directory. A child that keeps the parent's spool token writes
    # <token>-000000001.batch like its siblings and the atomic rename silently overwrites theirs.
    test "gives a forked child its own spool token so sibling workers do not overwrite batches" do
      skip "fork is not available" unless Process.respond_to?(:fork)

      dir = ::Dir.mktmpdir
      drain = build_drain(status: 503)
      logger = build_logger(drain, batch_size: 1, flush_interval: 0.01, spool_dir: dir)
      batches = -> { ::Dir.glob(::File.join(dir, "*.batch")) }

      capture_stderr do
        logger.add(Logger::INFO, "parent batch")
        assert wait_until { batches.call.size == 1 }, "the parent's failed batch should be spooled"

        pid = fork do
          logger.add(Logger::INFO, "child batch")
          wait_until { batches.call.size == 2 }
          exit!(0)
        end
        Process.wait(pid)
      end

      files = batches.call
      assert_equal 2, files.size, "expected one spool file per process, got #{files.map { |f| ::File.basename(f) }}"
      bodies = files.map { |file| ::File.read(file) }.join("\n")
      assert_includes bodies, "parent batch"
      assert_includes bodies, "child batch"
    ensure
      ::FileUtils.remove_entry(dir) if dir && ::File.directory?(dir)
    end

    test "restarts the sender thread on the next write if it died" do
      drain = build_drain
      logger = build_logger(drain, batch_size: 1, flush_interval: 0.01)

      logger.device.instance_variable_get(:@sender_thread).kill.join
      logger.add(Logger::INFO, "after sender death")

      assert wait_until { drain.received.include?("after sender death") },
        "a dead sender thread was not restarted; the app would log into a queue nobody reads"
    end

    # The device reports its own failures on $stderr. With a closed pipe or a detached tty that
    # write raises, and an exception inside the error path used to end the sender thread for good.
    test "keeps the sender thread alive when its own warnings cannot be written" do
      drain = build_drain(status: 503)
      logger = build_logger(drain, batch_size: 1, flush_interval: 0.01, circuit_cooldown: 0.3)
      sender = logger.device.instance_variable_get(:@sender_thread)

      reader, writer = IO.pipe
      reader.close
      with_stderr(writer) do
        5.times { |i| logger.add(Logger::INFO, "failing #{i}") }
        assert wait_until { logger.device.instance_variable_get(:@circuit_open_until) },
          "the failing drain should trip the circuit"

        drain.status = 200
        sleep 0.4
        logger.add(Logger::INFO, "after recovery")
        assert wait_until { drain.received.include?("after recovery") }
      end

      assert sender.alive?, "the sender thread died on a warning it could not write"
    ensure
      writer&.close
    end

    # onlylogs.io answers 404 to an unknown or deleted token and 403 to a paused project: no retry
    # will ever make such a batch acceptable. It must be dropped with a warning, not spooled, and
    # it must not open the circuit (the drain is up).
    test "drops a batch the drain rejects with a 4xx instead of spooling and retrying it" do
      dir = ::Dir.mktmpdir
      drain = build_drain(status: 404)
      logger = build_logger(drain, batch_size: 1, flush_interval: 0.01, spool_dir: dir)

      warnings = nil
      capture_stderr do
        3.times { |i| logger.add(Logger::INFO, "rejected #{i}") }
        assert wait_until { drain.bodies.size >= 3 }, "every batch should still be attempted"
        warnings = $stderr.string
      end

      assert_empty ::Dir.glob(::File.join(dir, "*.batch")), "a permanently rejected batch must not be spooled"
      assert_nil logger.device.instance_variable_get(:@circuit_open_until),
        "a 4xx means the drain is up; it must not open the circuit"
      assert_includes warnings, "404"
      assert_equal 1, warnings.scan("dropped").size, "one warning per cooldown, not one per batch"
    ensure
      logger&.close
      ::FileUtils.remove_entry(dir) if dir && ::File.directory?(dir)
    end

    # A rejected batch at the head of the spool must not block everything behind it forever.
    test "deletes a spooled batch the drain rejects on replay" do
      dir = ::Dir.mktmpdir
      Onlylogs::Spool.new(dir: dir).write("poison batch")

      drain = build_drain(status: 404)
      logger = build_logger(drain, batch_size: 1, flush_interval: 0.01, spool_dir: dir)

      capture_stderr do
        assert wait_until { ::Dir.glob(::File.join(dir, "*.batch")).empty? },
          "a spooled batch the drain rejects for good should be deleted, not retried forever"
      end
      assert_includes drain.received, "poison batch"
    ensure
      logger&.close
      ::FileUtils.remove_entry(dir) if dir && ::File.directory?(dir)
    end

    # A 429 is the drain asking us to slow down: honour Retry-After, keep the batch, and try again
    # later, without counting it as an outage.
    test "pauses for Retry-After and keeps the batch when the drain answers 429" do
      dir = ::Dir.mktmpdir
      drain = build_drain(status: 429, headers: {"Retry-After" => "1"})
      logger = build_logger(drain, batch_size: 1, flush_interval: 0.01, circuit_cooldown: 30, spool_dir: dir)

      capture_stderr do
        logger.add(Logger::INFO, "throttled line")
        open_until = wait_until { logger.device.instance_variable_get(:@circuit_open_until) }
        assert open_until, "a 429 should pause the sender"
        assert_in_delta 1, open_until - Time.now, 0.5, "the pause should follow Retry-After, not the cooldown"
        assert_equal 0, logger.device.instance_variable_get(:@consecutive_failures), "a 429 is not a failure"
        refute_empty ::Dir.glob(::File.join(dir, "*.batch")), "the throttled batch should be kept on disk"

        drain.status = 200
        assert wait_until { drain.received.include?("throttled line") }, "the batch should be replayed after the pause"
      end
    ensure
      logger&.close
      ::FileUtils.remove_entry(dir) if dir && ::File.directory?(dir)
    end

    # A batch never exceeds max_batch_bytes, and neither does a single line, so the drain can never
    # answer 413 to what we send.
    test "caps the batch body and truncates oversized lines" do
      drain = build_drain
      logger = build_logger(drain, batch_size: 1000, flush_interval: 0.05, max_batch_bytes: 200)

      10.times { |i| logger.add(Logger::INFO, "line #{i} #{"x" * 40}") }
      logger.add(Logger::INFO, "huge #{"y" * 500}")

      assert wait_until { drain.received.include?("truncated by onlylogs") }
      assert wait_until { drain.received.include?("line 9") }
      drain.bodies.each do |body|
        assert_operator body.bytesize, :<=, 200, "a batch body exceeded the cap: #{body.bytesize} bytes"
      end
      assert_equal 1, drain.bodies.count { |body| body.include?("huge") }
    end

    # After an outage the backlog is replayed one file per live batch, not all at once: replaying
    # everything first would let the live queue overflow, and every client of a drain that just
    # came back would hit it with its whole spool at full speed.
    test "interleaves spool replay with live batches instead of replaying the whole backlog first" do
      dir = ::Dir.mktmpdir
      previous = Onlylogs::Spool.new(dir: dir)
      200.times { |i| previous.write("spooled #{i}") }

      drain = build_drain
      logger = build_logger(drain, batch_size: 1, flush_interval: 0.01, spool_dir: dir)
      logger.add(Logger::INFO, "live line")

      assert wait_until(timeout: 10) { ::Dir.glob(::File.join(dir, "*.batch")).empty? }, "the spool should drain"
      bodies = drain.bodies
      live_at = bodies.index { |body| body.include?("live line") }
      assert live_at, "the live line should have been delivered"
      assert_operator live_at, :<, 100,
        "the live line was delivered after #{live_at} spooled batches; replay should interleave with live traffic"
    ensure
      logger&.close
      ::FileUtils.remove_entry(dir) if dir && ::File.directory?(dir)
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
      # The spool is on by default; disable it here for test isolation so unrelated tests don't
      # share the default on-disk spool dir. Spool tests pass an explicit spool_dir to opt back in.
      options = {spool_dir: nil}.merge(opts)
      Onlylogs::HttpLogger.new(drain_url: url, **options).tap { |logger| @loggers << logger }
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

    def capture_stderr(&block)
      with_stderr(StringIO.new, &block)
    end

    def with_stderr(io)
      original = $stderr
      $stderr = io
      yield
    ensure
      $stderr = original
    end
  end
end
