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
# By default an on-disk Spool buffers any batch we could not deliver and replays it once the
# drain recovers, so a transient outage or a restart does not lose logs. It is on by default
# (set ONLYLOGS_SPOOL_DIR empty to disable) and bounded by bytes; see Onlylogs::Spool.
#
# Every write checks that a sender thread is alive in the current process and starts one if not:
# * The device is usually built in the Puma master (production.rb runs before the workers are
#   forked with preload_app!) and inherited by every worker. Threads do not survive a fork, so
#   the child would have a queue nobody drains, a keep-alive socket shared with its siblings and a
#   spool token that makes siblings overwrite each other's batches. The first write in a new
#   process rebuilds all of that for the child.
# * The sender must never die, so its error path never raises (see #safe_warn) and every loop
#   iteration is rescued; should it die anyway, the next write restarts it.
module Onlylogs
  class HttpDevice
    DEFAULT_BATCH_SIZE = 100
    DEFAULT_FLUSH_INTERVAL = 0.5
    DEFAULT_MAX_QUEUE_SIZE = 10_000

    # Keep timeouts short: a single slow/dead drain must never stall the app for long.
    DEFAULT_OPEN_TIMEOUT = 0.5
    DEFAULT_READ_TIMEOUT = 0.5

    # How long Net::HTTP may keep an idle connection around for reuse. Comfortably longer than
    # the default flush interval so normal traffic reuses one connection across many batches.
    DEFAULT_KEEP_ALIVE_TIMEOUT = 30

    # Open the circuit after this many consecutive failed sends
    CIRCUIT_FAILURE_THRESHOLD = 3
    # ...and keep it open for this long once it is open.
    CIRCUIT_COOLDOWN = 30

    def initialize(
      drain_url: ENV["ONLYLOGS_DRAIN_URL"],
      batch_size: ENV.fetch("ONLYLOGS_BATCH_SIZE", DEFAULT_BATCH_SIZE).to_i,
      flush_interval: ENV.fetch("ONLYLOGS_FLUSH_INTERVAL", DEFAULT_FLUSH_INTERVAL).to_f,
      max_queue_size: ENV.fetch("ONLYLOGS_MAX_QUEUE_SIZE", DEFAULT_MAX_QUEUE_SIZE).to_i,
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
      enqueue(message.chomp)
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
    end

    private

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
      @spool = build_spool(@spool_dir, @spool_max_bytes) if @drain_url
      @consecutive_failures = 0
      @circuit_open_until = nil
      @dropped = 0
    end

    def start_sender
      @sender_thread = Thread.new do
        # Replay anything left in the spool by a previous run or a crashed/redeployed sibling.
        guard { drain_spool }
        sender_loop
      end
    end

    # Blocks on the queue instead of polling it: a partial batch waits for the rest of the flush
    # interval inside Queue#pop, so the thread costs nothing while idle. A full batch sends early;
    # a closed queue (see #close) ends the loop once it has been emptied.
    def sender_loop
      batch = []
      deadline = nil

      loop do
        line = @queue.pop(timeout: deadline && [deadline - monotonic_now, 0].max)
        break if line.nil? && @queue.closed?

        if line
          batch << line
          deadline ||= monotonic_now + @flush_interval
        end
        next if batch.empty?
        next unless batch.size >= @batch_size || monotonic_now >= deadline

        guard { send_batch(batch) }
        batch = []
        deadline = nil
      end

      guard { send_batch(batch) } if batch.any?
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
      # The drain just answered: replay anything we had buffered while it was unavailable.
      drain_spool
    rescue => e
      record_failure
      spool_write(body)
      safe_warn "Onlylogs::HttpDevice error: #{e.class}: #{e.message}"
    end

    def spool_write(body)
      @spool&.write(body)
    end

    # Replay buffered batches now that the drain is responding. Oldest first; stop at the first
    # failure (record it and leave the rest on disk) so a drain that just went down again does not
    # burn the whole backlog into the void.
    def drain_spool
      return unless @spool

      @spool.replay do |body|
        deliver(body)
        record_success
        true
      rescue => e
        record_failure
        safe_warn "Onlylogs::HttpDevice replay error: #{e.class}: #{e.message}"
        false
      end
    end

    def build_spool(dir, max_bytes)
      return if dir.nil? || dir.to_s.strip.empty?

      Spool.new(dir: dir, max_bytes: max_bytes)
    rescue => e
      safe_warn "Onlylogs::HttpDevice: spool disabled (#{e.class}: #{e.message})"
      nil
    end

    # The spool is on by default. It lives under the app's tmp dir, which survives a drain outage
    # while the app keeps running; point ONLYLOGS_SPOOL_DIR at a persistent volume to also survive
    # redeploys, or set it empty to disable.
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

    # Net::HTTP does not raise on 4xx/5xx; it returns the response. Treat any non-2xx as a
    # failed delivery so send_batch records it and the circuit can open. Without this a drain
    # that is up but answering 500/413 would look like success and we'd silently drop every batch.
    def ensure_success!(response)
      return if response.is_a?(Net::HTTPSuccess)

      raise "drain responded #{response.code} #{response.message}"
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
      @mutex.synchronize { !@circuit_open_until.nil? && Time.now < @circuit_open_until }
    end

    def record_success
      @mutex.synchronize do
        @consecutive_failures = 0
        @circuit_open_until = nil
      end
    end

    def record_failure
      opened = false
      dropped = 0

      @mutex.synchronize do
        @consecutive_failures += 1
        next if @consecutive_failures < CIRCUIT_FAILURE_THRESHOLD

        # (Re)open the circuit. record_failure only runs on a real send attempt — send_batch
        # short-circuits while the circuit is open — so reaching here always means the drain
        # is still down and we should pause again (this is how recovery retries every cooldown).
        @circuit_open_until = Time.now + @circuit_cooldown
        opened = true
        dropped = @dropped
        @dropped = 0
      end

      # Warn outside the mutex:
      # doing it inside the lock would re-enter @mutex through record_failure and raise a recursive-lock error.
      return unless opened

      suffix = dropped.positive? ? " (#{dropped} log lines dropped)" : ""
      safe_warn "Onlylogs::HttpDevice: drain unavailable, pausing for #{@circuit_cooldown}s#{suffix}"
    end
  end
end
