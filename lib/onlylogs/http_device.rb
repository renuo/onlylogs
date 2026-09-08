# frozen_string_literal: true

require "net/http"
require "uri"
require_relative "spool"

# A Logger log device that sends log lines to onlylogs.io (or any Vector-compatible sink) directly
# via HTTP.
#
# When the drain is unreachable or unresponsive, we do two things to protect the app:
# * an upper bound to the in-memory queue: log lines can never accumulate without limit and exhaust memory
# * cooldown: once the drain is known to be failing we stop attempting
#   requests for a cooldown period instead of blocking on every send for the full
#   read timeout (a down host accepts the TCP/TLS connection but never answers).
#
# By default an on-disk spool buffers any batch we could not deliver and replays it once the
# drain recovers, so a transient outage or a restart does not lose logs. It is on by default
# (set ONLYLOGS_SPOOL_DIR empty to disable) and bounded by bytes. Each process spools into its own
# directory; see Onlylogs::Spool.
#
# Every write checks that a sender thread is alive in the current process and starts one if not:
# * The device is usually built in the Puma master (production.rb runs before the workers are
#   forked with preload_app!) and inherited by every worker. Threads do not survive a fork, so
#   the child would have a queue nobody drains, a keep-alive socket shared with its siblings and
#   the parent's spool directory. The first write in a new process rebuilds all of that for the
#   child.
# * The sender must never die, so its error path never raises (see #safe_warn) and every loop
#   iteration is rescued; should it die anyway, the next write restarts it.
#
# Not every failure is worth retrying. The drain's answer decides what happens to a batch:
# * 2xx: delivered.
# * 429: the drain is overloaded and asks us to slow down. Pause for Retry-After (or a cooldown)
#   and keep the batch on disk; nothing is lost, it is just late.
# * other 4xx: the drain will never accept this batch (unknown token, paused project, body too
#   big). Retrying cannot help, so the batch is dropped and a warning says why.
# * 5xx, timeouts, connection errors: retryable. Count towards opening the circuit and spool.
module Onlylogs
  class HttpDevice
    # The drain answered with a 4xx other than 429: the batch itself is the problem, not the drain.
    class Rejected < StandardError; end

    # The drain answered 429: it is up but wants us to back off.
    class Throttled < StandardError
      attr_reader :retry_after

      def initialize(message, retry_after: nil)
        super(message)
        @retry_after = retry_after
      end
    end

    DEFAULT_BATCH_SIZE = 100
    DEFAULT_FLUSH_INTERVAL = 0.5
    DEFAULT_MAX_QUEUE_SIZE = 10_000

    # A batch body never exceeds this many bytes, and neither does a single line: a drain cannot
    # answer 413 to a request we never make. Lines over the cap are cut and marked.
    DEFAULT_MAX_BATCH_BYTES = 1024 * 1024

    # Keep timeouts short: a single slow/dead drain must never stall the app for long.
    DEFAULT_OPEN_TIMEOUT = 0.5
    DEFAULT_READ_TIMEOUT = 0.5

    # How long Net::HTTP may keep an idle connection around for reuse. Comfortably longer than
    # the default flush interval so normal traffic reuses one connection across many batches.
    DEFAULT_KEEP_ALIVE_TIMEOUT = 30

    # An idle sender wakes this often to look for spool directories dead siblings left behind.
    ORPHAN_CHECK_INTERVAL = 5

    # Open the circuit after this many consecutive failed sends
    CIRCUIT_FAILURE_THRESHOLD = 3
    # ...and keep it open for about this long once it is open. The actual pause is jittered
    # between 0.5x and 1.5x so that every client of a drain that just came back does not retry in
    # the same second.
    CIRCUIT_COOLDOWN = 30

    def initialize(
      drain_url: ENV["ONLYLOGS_DRAIN_URL"],
      batch_size: ENV.fetch("ONLYLOGS_BATCH_SIZE", DEFAULT_BATCH_SIZE).to_i,
      flush_interval: ENV.fetch("ONLYLOGS_FLUSH_INTERVAL", DEFAULT_FLUSH_INTERVAL).to_f,
      max_queue_size: ENV.fetch("ONLYLOGS_MAX_QUEUE_SIZE", DEFAULT_MAX_QUEUE_SIZE).to_i,
      max_batch_bytes: ENV.fetch("ONLYLOGS_MAX_BATCH_BYTES", DEFAULT_MAX_BATCH_BYTES).to_i,
      open_timeout: ENV.fetch("ONLYLOGS_OPEN_TIMEOUT", DEFAULT_OPEN_TIMEOUT).to_f,
      read_timeout: ENV.fetch("ONLYLOGS_READ_TIMEOUT", DEFAULT_READ_TIMEOUT).to_f,
      circuit_cooldown: ENV.fetch("ONLYLOGS_CIRCUIT_COOLDOWN", CIRCUIT_COOLDOWN).to_f,
      keep_alive_timeout: ENV.fetch("ONLYLOGS_KEEP_ALIVE_TIMEOUT", DEFAULT_KEEP_ALIVE_TIMEOUT).to_f,
      spool_dir: ENV.fetch("ONLYLOGS_SPOOL_DIR", default_spool_dir),
      spool_max_bytes: ENV.fetch("ONLYLOGS_SPOOL_MAX_BYTES", Spool::DEFAULT_MAX_BYTES).to_i
    )
      @drain_url = drain_url
      @uri = URI.parse(drain_url) if drain_url
      @batch_size = batch_size
      @flush_interval = flush_interval
      @max_queue_size = max_queue_size
      @max_batch_bytes = max_batch_bytes
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @circuit_cooldown = circuit_cooldown
      @keep_alive_timeout = keep_alive_timeout
      @spool_dir = spool_dir
      @spool_max_bytes = spool_max_bytes
      @supervisor_mutex = Mutex.new
      reset_process_state

      if @drain_url
        start_sender
        # at_exit procs are inherited by forked children, so this is registered exactly once: a
        # child that rebuilt its state after the fork closes through the same block.
        at_exit { close }
      else
        safe_warn "Onlylogs::HttpDevice: ONLYLOGS_DRAIN_URL is not set; logging locally only."
      end
    end

    # Receives the already-formatted, already-level-filtered line from Logger#add.
    def write(message)
      return if message.nil? || message.empty?
      # No drain configured: nothing to ship. The local fallback (see MultiDevice) still logs it.
      return unless @drain_url

      ensure_sender
      enqueue(truncate(message.chomp))
    end

    # Ships everything still queued, then stops the sender. This is the only synchronous path: there
    # is deliberately no #flush, when to ship is the sender's decision (batch size or interval).
    def close
      # A forked child that never logged owns nothing here: the queued lines and the connection
      # belong to the parent, and finishing an inherited TLS socket would send close_notify on it.
      return if forked?

      @queue.close
      @sender_thread&.join(2)
      close_connection
      @spool&.close
    end

    private

    TRUNCATION_MARKER = "...[truncated by onlylogs]"

    def truncate(line)
      return line if line.bytesize <= @max_batch_bytes

      line.byteslice(0, @max_batch_bytes - TRUNCATION_MARKER.bytesize).scrub("") + TRUNCATION_MARKER
    end

    # Push a line onto the queue unless it is full. Dropping is intentional: blocking the
    # caller (a request thread) or growing without bound (OOM) are both worse than losing
    # logs while the drain is unavailable.
    def enqueue(line)
      if @queue.size >= @max_queue_size
        @mutex.synchronize { @dropped += 1 }
        return
      end

      @queue << line
    rescue ClosedQueueError
      nil
    end

    # Cheap on the hot path (a getpid and a thread status check); only the first write after a fork
    # or after the sender died pays for the rebuild. Several request threads can race here in a
    # fresh worker, hence the double check under the lock.
    def ensure_sender
      return if sender_healthy?

      @supervisor_mutex.synchronize do
        next if sender_healthy?

        # Deliberately no close_connection here: after a fork the inherited socket is still in use
        # by the parent, and lines left in the inherited queue are the parent's to ship.
        reset_process_state if forked?
        start_sender
      end
    end

    # A closed queue means #close ran: there is nothing left to supervise.
    def sender_healthy?
      !forked? && (@queue.closed? || @sender_thread&.alive?)
    end

    def forked?
      Process.pid != @pid
    end

    def reset_process_state
      @pid = Process.pid
      @queue = Queue.new
      @mutex = Mutex.new
      @http_mutex = Mutex.new
      @http = nil
      @sender_thread = nil
      @spool&.detach
      @spool = build_spool(@spool_dir, @spool_max_bytes) if @drain_url
      @consecutive_failures = 0
      @circuit_open_until = nil
      @dropped = 0
      @rejected = 0
      @rejection_warned_at = nil
    end

    def start_sender
      @sender_thread = Thread.new { sender_loop }
    end

    # Blocks on the queue instead of polling it: a partial batch waits for the rest of the flush
    # interval inside Queue#pop, so the thread costs nothing while idle. A full batch sends early;
    # a closed queue (see #close) ends the loop once it has been emptied.
    #
    # The spool (batches left by an outage, or by a previous run) is replayed one file at a time
    # between live batches, never all at once: the live queue must not overflow while we catch up,
    # and a drain that just recovered must not be hit with every client's whole backlog at full
    # speed. While the queue is idle the loop keeps replaying, one file per turn.
    def sender_loop
      batch = []
      bytes = 0
      deadline = nil
      guard { @spool&.adopt_orphans }

      loop do
        line = @queue.pop(timeout: pop_timeout(deadline))
        break if line.nil? && @queue.closed?

        if line
          if batch.any? && bytes + line.bytesize + 1 > @max_batch_bytes
            guard { send_batch(batch) }
            batch = []
            bytes = 0
            deadline = nil
          end
          batch << line
          bytes += line.bytesize + 1
          deadline ||= monotonic_now + @flush_interval
        end

        if batch.any? && (batch.size >= @batch_size || monotonic_now >= deadline)
          guard { send_batch(batch) }
          batch = []
          bytes = 0
          deadline = nil
          guard { replay_one }
        elsif line.nil?
          guard { replay_one }
        end
      end

      guard { send_batch(batch) } if batch.any?
    end

    # How long the sender may block waiting for the next line: until the partial batch is due,
    # until the circuit closes if there is a backlog to replay, not at all if we can replay right
    # now, or until the next look for orphaned spool directories when there is nothing to do.
    def pop_timeout(deadline)
      return [deadline - monotonic_now, 0].max if deadline
      return circuit_remaining if spool_pending?

      ORPHAN_CHECK_INTERVAL
    end

    def spool_pending?
      !@spool.nil? && !@spool.empty?
    end

    # Last line of defence for the sender thread: whatever escapes the per-batch handling is
    # reported and the batch given up, never the thread.
    def guard
      yield
    rescue => e
      safe_warn "Onlylogs::HttpDevice sender error: #{e.class}: #{e.message}"
    end

    # All of the device's own diagnostics go through here. Kernel.warn itself raises when $stderr is
    # a closed pipe or a detached tty (EPIPE, EIO, IOError), and an exception inside an error path
    # would take the sender thread down with it.
    def safe_warn(message)
      Kernel.warn(message)
    rescue
      nil
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def send_batch(lines)
      return if lines.empty?

      body = lines.join("\n")

      # Drain is known to be down: skip the request entirely so we don't block for the full read
      # timeout on every batch. Buffer the batch so the cooldown does not cost us data (without a
      # spool configured, spool_write is a no-op and the batch is dropped — best-effort logging).
      if circuit_open?
        spool_write(body)
        return
      end

      deliver(body)
      record_success
    rescue Rejected => e
      record_rejection(lines.size, e)
    rescue Throttled => e
      record_throttle(e)
      spool_write(body)
    rescue => e
      record_failure
      spool_write(body)
      safe_warn "Onlylogs::HttpDevice error: #{e.class}: #{e.message}"
    end

    def spool_write(body)
      @spool&.write(body)
    end

    # Replay the oldest buffered batch, if the drain is believed to be up. A batch the drain rejects
    # for good is deleted too, otherwise it would sit at the head of the spool forever and block
    # everything behind it. With nothing of its own left, the sender takes a share of whatever dead
    # siblings left behind.
    def replay_one
      return if @spool.nil? || circuit_open?

      @spool.adopt_orphans if @spool.empty?
      @spool.replay(limit: 1) do |body|
        deliver(body)
        record_success
        true
      rescue Rejected => e
        record_rejection(body.count("\n") + 1, e)
        true
      rescue Throttled => e
        record_throttle(e)
        false
      rescue => e
        record_failure
        safe_warn "Onlylogs::HttpDevice replay error: #{e.class}: #{e.message}"
        false
      end
    rescue => e
      # The spool itself failed (not the delivery). Counting it as a failure lets the circuit pace
      # the retries instead of the sender loop spinning on it.
      record_failure
      safe_warn "Onlylogs::HttpDevice spool error: #{e.class}: #{e.message}"
    end

    def build_spool(dir, max_bytes)
      return if dir.nil? || dir.to_s.strip.empty?

      Spool.new(dir: dir, max_bytes: max_bytes)
    rescue => e
      safe_warn "Onlylogs::HttpDevice: spool disabled (#{e.class}: #{e.message})"
      nil
    end

    # The spool is on by default. It lives under the app's tmp dir, which survives a drain outage
    # while the app keeps running; point ONLYLOGS_SPOOL_DIR at a persistent, host-local volume to
    # also survive redeploys, or set it empty to disable.
    def default_spool_dir
      base = if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        Rails.root.to_s
      else
        ::Dir.pwd
      end

      ::File.join(base, "tmp", "onlylogs", "spool")
    end

    # POST the body over a persistent (kept-alive) connection.
    def deliver(body)
      @http_mutex.synchronize do
        attempts = 0
        response = begin
          attempts += 1
          reused = !@http.nil?
          connection.request(build_request(body))
        rescue
          close_connection
          retry if reused && attempts < 2
          raise
        end

        # Checked outside the rescue on purpose: a non-2xx is an application-level error on a
        # healthy connection, so it must NOT trigger the reconnect-retry above (that would hammer
        # an erroring drain on a perfectly good socket). Raising here records a failure instead.
        ensure_success!(response)
      end
    end

    # Net::HTTP does not raise on 4xx/5xx; it returns the response. Every non-2xx raises so the
    # caller can tell a drain that is down (retry) from one that refuses the batch (drop) or asks
    # us to slow down (pause). The drain's body is included: onlylogs.io says why in one line.
    def ensure_success!(response)
      return if response.is_a?(Net::HTTPSuccess)

      message = "drain responded #{response.code} #{response.message}"
      detail = response.body.to_s.lines.first.to_s.strip
      message += " (#{detail[0, 80]})" unless detail.empty?

      case response
      when Net::HTTPTooManyRequests
        raise Throttled.new(message, retry_after: parse_retry_after(response["Retry-After"]))
      when Net::HTTPClientError
        raise Rejected, message
      else
        raise message
      end
    end

    # Only the delay-seconds form; an HTTP-date is rare and the cooldown is a fine fallback.
    def parse_retry_after(value)
      seconds = Integer(value.to_s, 10, exception: false)
      seconds if seconds&.positive?
    end

    def build_request(body)
      # request_uri (not path): it defaults to "/" when the drain URL has no path — Net::HTTP::Post.new("")
      # raises "HTTP request path is empty" — and it carries any query string (e.g. ?token=...) along.
      request = Net::HTTP::Post.new(@uri.request_uri)
      request.body = body
      request.content_type = "text/plain"
      request
    end

    # Lazily opens and memoizes the connection. Only assigns @http once #start succeeds, so a
    # failed connect leaves @http nil and the next send starts clean. Caller holds @http_mutex.
    def connection
      return @http if @http

      http = Net::HTTP.new(@uri.host, @uri.port)
      http.use_ssl = (@uri.scheme == "https")
      http.read_timeout = @read_timeout
      http.open_timeout = @open_timeout
      http.keep_alive_timeout = @keep_alive_timeout
      http.start
      @http = http
    end

    # Caller holds @http_mutex, or no other thread can touch @http (shutdown after the sender
    # thread has joined).
    def close_connection
      @http&.finish
    rescue IOError
      # already closed
    ensure
      @http = nil
    end

    def circuit_open?
      circuit_remaining.positive?
    end

    # Seconds until the circuit closes again; 0 when it is closed.
    def circuit_remaining
      @mutex.synchronize { @circuit_open_until ? [@circuit_open_until - Time.now, 0].max : 0 }
    end

    def record_success
      @mutex.synchronize do
        @consecutive_failures = 0
        @circuit_open_until = nil
      end
    end

    def record_failure
      pause = nil
      dropped = 0

      @mutex.synchronize do
        @consecutive_failures += 1
        next if @consecutive_failures < CIRCUIT_FAILURE_THRESHOLD

        # (Re)open the circuit. record_failure only runs on a real send attempt — send_batch
        # short-circuits while the circuit is open — so reaching here always means the drain
        # is still down and we should pause again (this is how recovery retries every cooldown).
        pause = jittered_cooldown
        @circuit_open_until = Time.now + pause
        dropped = @dropped
        @dropped = 0
      end

      # Warn outside the mutex:
      # doing it inside the lock would re-enter @mutex through record_failure and raise a recursive-lock error.
      return unless pause

      suffix = dropped.positive? ? " (#{dropped} log lines dropped)" : ""
      safe_warn "Onlylogs::HttpDevice: drain unavailable, pausing for #{pause.round}s#{suffix}"
    end

    # A 429 is not an outage: the drain is up and told us how long to wait. Open the circuit for
    # that long without counting a failure, so the batch goes to the spool and is replayed later.
    def record_throttle(error)
      pause = error.retry_after || jittered_cooldown
      @mutex.synchronize { @circuit_open_until = Time.now + pause }
      safe_warn "Onlylogs::HttpDevice: #{error.message}, pausing for #{pause.round}s"
    end

    # The drain is up (so the circuit stays closed) but refuses this batch for good. One warning
    # per cooldown period, with the running count, rather than one per batch: an unknown token
    # rejects every single batch and would otherwise flood stderr.
    def record_rejection(line_count, error)
      rejected = nil

      @mutex.synchronize do
        @consecutive_failures = 0
        @rejected += line_count
        next unless @rejection_warned_at.nil? || monotonic_now - @rejection_warned_at >= @circuit_cooldown

        rejected = @rejected
        @rejected = 0
        @rejection_warned_at = monotonic_now
      end

      return unless rejected

      safe_warn "Onlylogs::HttpDevice: #{error.message}, dropped #{rejected} log lines the drain will not accept"
    end

    def jittered_cooldown
      @circuit_cooldown * (0.5 + rand)
    end
  end
end
