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
  #
  # Those siblings replay the same directory too. A file is claimed with an atomic rename before it
  # is delivered, so each batch is shipped by one worker only; a claim a dead worker left behind is
  # handed back after STALE_CLAIM_AFTER seconds.
  class Spool
    DEFAULT_MAX_BYTES = 128 * 1024 * 1024 # 128 MB
    LEDGER_TTL = 5
    CLAIM_SUFFIX = ".sending"
    STALE_CLAIM_AFTER = 60

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
      @quarantined = Set.new
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
      safe_warn "Onlylogs::Spool write error: #{e.class}: #{e.message}"
    end

    # Replay pending batches oldest-first, at most `limit` of them. Yields each body; if the block
    # returns truthy the file is deleted (delivered, or given up on), otherwise replay stops and the
    # remaining files are kept for later.
    #
    # Works off the ledger rather than listing the directory: with a large backlog replayed one file
    # at a time, a glob per call would cost more than the delivery itself.
    def replay(limit: nil)
      paths = @mutex.synchronize do
        refresh_ledger if ledger_stale?
        @ledger.first(limit || @ledger.size).map(&:first)
      end

      paths.each do |path|
        sending = path + CLAIM_SUFFIX
        body = claim(path, sending)
        if body.nil? # taken by another process, or quarantined
          forget(path)
          next
        end

        unless yield(body)
          release(sending, path)
          break
        end

        delete(sending)
        forget(path)
      end
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
      reclaim_stale_claims
      ::Dir.glob(::File.join(@dir, "*.batch")).reject { |path| @quarantined.include?(path) }
        .sort_by { |path| [mtime(path), path] }
    end

    # A worker that died mid-delivery leaves its claim behind. Hand such files back so they are not
    # lost; the claim's touched mtime puts them at the back of the queue.
    def reclaim_stale_claims
      cutoff = Time.now - STALE_CLAIM_AFTER
      ::Dir.glob(::File.join(@dir, "*#{CLAIM_SUFFIX}")).each do |sending|
        next unless mtime(sending) < cutoff

        ::File.rename(sending, sending.delete_suffix(CLAIM_SUFFIX))
      rescue SystemCallError
        nil
      end
    end

    def mtime(path)
      ::File.mtime(path)
    rescue Errno::ENOENT
      Time.at(0)
    end

    # Replay is oldest-first and so is the ledger, so the path is nearly always the head.
    def forget(path)
      @mutex.synchronize do
        next if @ledger.nil?

        index = (@ledger.first&.first == path) ? 0 : @ledger.index { |candidate, _| candidate == path }
        next unless index

        @ledger_bytes -= @ledger.delete_at(index).last
      end
    end

    # Take the file away from sibling workers, then read it. Rename is atomic within a directory,
    # so the loser of a race gets ENOENT. The mtime is bumped so a stale claim can be told apart
    # from the batch's own age.
    def claim(path, sending)
      ::File.rename(path, sending)
      now = Time.now
      ::File.utime(now, now, sending)
      ::File.binread(sending)
    rescue Errno::ENOENT
      nil
    rescue SystemCallError => e
      quarantine(path, "claim", e)
      nil
    end

    def release(sending, path)
      ::File.rename(sending, path)
    rescue SystemCallError => e
      safe_warn "Onlylogs::Spool: cannot release #{sending} (#{e.class}: #{e.message})"
    end

    def delete(path)
      ::File.delete(path)
    rescue Errno::ENOENT
      nil
    rescue SystemCallError => e
      quarantine(path.delete_suffix(CLAIM_SUFFIX), "delete", e)
    end

    # A file this process cannot claim, read or delete (a directory, another owner, a read-only
    # volume) is left alone for the rest of the process: retrying it would fail the same way, in a
    # tight loop. May run with or without @mutex held (evict vs replay).
    def quarantine(path, action, error)
      if @mutex.owned?
        @quarantined << path
      else
        @mutex.synchronize { @quarantined << path }
      end
      safe_warn "Onlylogs::Spool: cannot #{action} #{path} (#{error.class}: #{error.message}), skipping it"
    end

    # Kernel.warn itself raises on a closed or detached $stderr, and that must not escape the
    # sender thread.
    def safe_warn(message)
      Kernel.warn(message)
    rescue
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
