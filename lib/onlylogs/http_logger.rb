# frozen_string_literal: true

require "net/http"
require "uri"

# This logger sends messages to onlylogs.io (or any Vector-compatible sink) directly via HTTP.
# Unlike SocketLogger, it does not require a sidecar process or Puma plugin,
# so it works from any process: Puma, GoodJob, Sidekiq, rake tasks, migrations, etc.

module Onlylogs
  class HttpLogger < Onlylogs::Logger
    DEFAULT_BATCH_SIZE = 100
    DEFAULT_FLUSH_INTERVAL = 0.5

    def initialize(
      local_fallback: $stdout,
      drain_url: ENV["ONLYLOGS_DRAIN_URL"],
      batch_size: ENV.fetch("ONLYLOGS_BATCH_SIZE", DEFAULT_BATCH_SIZE).to_i,
      flush_interval: ENV.fetch("ONLYLOGS_FLUSH_INTERVAL", DEFAULT_FLUSH_INTERVAL).to_f
    )
      super(local_fallback)
      @drain_url = drain_url
      @batch_size = batch_size
      @flush_interval = flush_interval
      @queue = Queue.new
      @mutex = Mutex.new

      if @drain_url
        start_sender
      else
        $stderr.puts "Onlylogs::HttpLogger error: ONLYLOGS_DRAIN_URL is not set; logger is disabled."
      end
    end

    def add(severity, message = nil, progname = nil, &block)
      return true unless @drain_url

      if message.nil?
        if block_given?
          message = block.call
        else
          message = progname
          progname = nil
        end
      end

      formatted = format_message(format_severity(severity), Time.now, progname, message.to_s)
      @queue << formatted if formatted && @drain_url
      super
    end

    def close
      flush
      @running = false
      @sender_thread&.join(2)
    end

    def flush
      send_batch(drain_queue)
    end

    private

    def start_sender
      @running = true

      @sender_thread = Thread.new do
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

      uri = URI.parse(@drain_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.read_timeout = 5
      http.open_timeout = 2

      request = Net::HTTP::Post.new(uri.path)
      request.body = lines.join("\n")
      request.content_type = "text/plain"

      http.start { |h| h.request(request) }
    rescue => e
      warn "Onlylogs::HttpLogger error: #{e.class}: #{e.message}"
    end
  end
end
