# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Onlylogs
  # A bounded, on-disk overflow buffer for log batches that could not be delivered.
  #
  # HttpLogger keeps the happy path in memory: only when a send fails or the circuit is open does
  # a batch get written here, to be replayed once the drain recovers (and on the next boot).
  # This turns transient-failure / restart data loss into at-least-once delivery: a batch that was in
  # fact received but whose response was lost will be replayed and show up as a duplicate
  # downstream. Duplicates are an accepted trade for not losing data.
  #
  # The byte cap is enforced from an in-memory ledger of the files in the directory, refreshed by
  # listing the directory at most every LEDGER_TTL seconds (sibling processes such as other Puma
  # workers write to the same directory), so a write costs one file and not a stat of every file.
  class Spool
    DEFAULT_MAX_BYTES = 128 * 1024 * 1024 # 128 MB
    LEDGER_TTL = 5

    def initialize(dir:, max_bytes: DEFAULT_MAX_BYTES)
      @dir = dir
      @max_bytes = max_bytes
      # Unique per instance so two runs (even with a reused pid) never collide on a filename.
      @token = SecureRandom.hex(4)
      @seq = 0
      @mutex = Mutex.new
      @ledger = nil
      @ledger_bytes = 0
      @ledger_at = nil
      ::FileUtils.mkdir_p(@dir)
    end

    # Persist a batch body. Rolls the oldest batches off first if the byte cap would be exceeded.
    def write(body)
      return if body.nil? || body.empty?

      @mutex.synchronize do
        refresh_ledger if ledger_stale?
        evict(body.bytesize)
        seq = (@seq += 1)
        final = ::File.join(@dir, "#{@token}-#{format("%09d", seq)}.batch")
        tmp = "#{final}.tmp"
        # Write to a temp name then rename: rename is atomic, so replay never reads a
        # half-written file (it only globs *.batch).
        ::File.binwrite(tmp, body)
        ::File.rename(tmp, final)
        @ledger << [final, body.bytesize]
        @ledger_bytes += body.bytesize
      end
    rescue => e
      Kernel.warn "Onlylogs::Spool write error: #{e.class}: #{e.message}"
    end

    # Replay pending batches oldest-first. Yields each body; if the block returns truthy the file
    # is deleted (delivered), otherwise replay stops and the remaining files are kept for later.
    def replay
      return if empty?

      pending_files.each do |path|
        body = read(path)
        next if body.nil? # already claimed/deleted by another process

        break unless yield(body)

        delete(path)
      end
    ensure
      @mutex.synchronize { @ledger = nil }
    end

    def empty?
      @mutex.synchronize do
        refresh_ledger if ledger_stale?
        @ledger.empty?
      end
    end

    private

    def ledger_stale?
      @ledger.nil? || Process.clock_gettime(Process::CLOCK_MONOTONIC) - @ledger_at > LEDGER_TTL
    end

    # Caller holds @mutex.
    def refresh_ledger
      @ledger = pending_files.map { |path| [path, size(path)] }
      @ledger_bytes = @ledger.sum { |_, bytes| bytes }
      @ledger_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Oldest-first. mtime is the primary key; the zero-padded sequence in the filename breaks
    # ties (and preserves per-process write order when mtimes collide at coarse FS resolution).
    def pending_files
      ::Dir.glob(::File.join(@dir, "*.batch")).sort_by { |path| [mtime(path), path] }
    end

    def mtime(path)
      ::File.mtime(path)
    rescue Errno::ENOENT
      Time.at(0)
    end

    def read(path)
      ::File.binread(path)
    rescue Errno::ENOENT
      nil
    end

    def delete(path)
      ::File.delete(path)
    rescue Errno::ENOENT
      nil
    end

    # Delete oldest batches until `incoming` more bytes fit under the cap. Caller holds @mutex.
    def evict(incoming)
      while @ledger_bytes + incoming > @max_bytes && (oldest = @ledger.shift)
        path, bytes = oldest
        delete(path)
        @ledger_bytes -= bytes
      end
    end

    def size(path)
      ::File.size(path)
    rescue Errno::ENOENT
      0
    end
  end
end
