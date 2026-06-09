# frozen_string_literal: true

require "net/http"
require "uri"
require_relative "spool"

# This logger sends messages to onlylogs.io (or any Vector-compatible sink) directly via HTTP.
# Unlike SocketLogger, it does not require a sidecar process or Puma plugin,
# so it works from any process: Puma, GoodJob, Sidekiq, rake tasks, migrations, etc.

# When the drain is unreachable or unresponsive, we do two things to protect the app:
# * an upper bound to the in-memory queue: log lines can never accumulate without limit and
#   exhaust memory
# * cooldown: once the drain is known to be failing we stop attempting
#   requests for a cooldown period instead of blocking on every send for the full
#   read timeout (a down host accepts the TCP/TLS connection but never answers).
#
# By default an on-disk Spool buffers any batch we could not deliver and replays it once the
# drain recovers, so a transient outage or a restart does not lose logs. It is on by default
# (set ONLYLOGS_SPOOL_DIR empty to disable) and bounded by bytes; see Onlylogs::Spool.
module Onlylogs
  class HttpLogger < Onlylogs::Logger
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
      local_fallback: $stdout,
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
      super(local_fallback)
      @drain_url = drain_url
      @uri = URI.parse(drain_url) if drain_url
      @batch_size = batch_size
      @flush_interval = flush_interval
      @max_queue_size = max_queue_size
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @circuit_cooldown = circuit_cooldown
      @keep_alive_timeout = keep_alive_timeout
      @queue = Queue.new
      @mutex = Mutex.new
      @http_mutex = Mutex.new
      @http = nil
      @spool = nil

      @consecutive_failures = 0
      @circuit_open_until = nil
      @dropped = 0

      if @drain_url
        @spool = build_spool(spool_dir, spool_max_bytes)
        start_sender
      else
        $stderr.puts "Onlylogs::HttpLogger: ONLYLOGS_DRAIN_URL is not set; logging locally only." # rubocop:disable Style/StderrPuts
      end
    end

    def add(severity, message = nil, progname = nil, &block)
      # No drain configured: behave as a plain local logger instead of dropping everything.
      return super unless @drain_url

      if message.nil?
        if block_given?
          message = block.call
        else
          message = progname
          progname = nil
        end
      end

      formatted = format_message(format_severity(severity), Time.now, progname, message.to_s)
      enqueue(formatted.chomp) if formatted
      super
    end

    def close
      flush
      @running = false
      @sender_thread&.join(2)
      close_connection
    end

    def flush
      send_batch(drain_queue)
      super
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
    end

    def start_sender
      @running = true

      @sender_thread = Thread.new do
        # Replay anything left in the spool by a previous run or a crashed/redeployed sibling.
        drain_spool

        batch = []
        last_flush = Time.now

        while @running || !@queue.empty?
          begin
            line = @queue.pop(true)
            batch << line if line
          rescue ThreadError
            # queue empty
          end

          if batch.any? && (batch.size >= @batch_size || (Time.now - last_flush) >= @flush_interval)
            send_batch(batch)
            batch = []
            last_flush = Time.now
          end

          sleep 0.01 if batch.empty?
        end

        send_batch(batch) if batch.any?
      end

      at_exit { close }
    end

    def drain_queue
      lines = []
      lines << @queue.pop(true) until @queue.empty?
      lines
    rescue ThreadError
      lines
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
      Kernel.warn "Onlylogs::HttpLogger error: #{e.class}: #{e.message}"
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
        Kernel.warn "Onlylogs::HttpLogger replay error: #{e.class}: #{e.message}"
        false
      end
    end

    def build_spool(dir, max_bytes)
      return if dir.nil? || dir.to_s.strip.empty?

      Spool.new(dir: dir, max_bytes: max_bytes)
    rescue => e
      Kernel.warn "Onlylogs::HttpLogger: spool disabled (#{e.class}: #{e.message})"
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
      # doing it inside the lock would re-enter @mutex through add -> enqueue and raise a recursive-lock error.
      return unless opened

      suffix = dropped.positive? ? " (#{dropped} log lines dropped)" : ""
      Kernel.warn "Onlylogs::HttpLogger: drain unavailable, pausing for #{@circuit_cooldown}s#{suffix}"
    end
  end
end
