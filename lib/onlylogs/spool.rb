# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Onlylogs
  # A bounded, on-disk overflow buffer for batches that could not be delivered.
  #
  # Every process spools into its own directory under `dir` and holds an flock on it for as long as
  # it lives, so no two processes ever touch the same file. The kernel releases the lock when the
  # process dies; live processes adopt the batches of every directory whose lock is free, a chunk at
  # a time so that a big backlog is shared between them, and replay them. Delivery is at least once:
  # a batch that was received but whose response was lost is replayed and shows up downstream twice.
  # Duplicates are an accepted trade for not losing data.
  #
  # One thread owns an instance; it is not thread-safe. The directory must be on a host-local
  # filesystem, flock over NFS is not reliable.
  class Spool
    DEFAULT_MAX_BYTES = 128 * 1024 * 1024 # 128 MB
    ADOPTION_CHUNK = 100

    attr_reader :dir

    def initialize(dir:, max_bytes: DEFAULT_MAX_BYTES)
      @root = dir
      @max_bytes = max_bytes
      @seq = 0
      @ledger = [] # [path, bytes], oldest first
      @bytes = 0
      ::FileUtils.mkdir_p(@root)
      @dir = claim_directory
    end

    # Persist a batch body. Rolls the oldest batches off first if the byte cap would be exceeded.
    def write(body)
      return if body.nil? || body.empty?

      evict(body.bytesize)
      path = next_path
      tmp = "#{path}.tmp"
      # Write to a temp name then rename, so a crash mid-write never leaves a torn batch for the
      # process that adopts this directory.
      ::File.binwrite(tmp, body)
      ::File.rename(tmp, path)
      @ledger << [path, body.bytesize]
      @bytes += body.bytesize
    rescue => e
      safe_warn "Onlylogs::Spool write error: #{e.class}: #{e.message}"
    end

    # Replay pending batches oldest-first, at most `limit` of them. Yields each body; if the block
    # returns truthy the file is deleted (delivered, or given up on), otherwise replay stops and the
    # batch stays at the head for later.
    def replay(limit: nil)
      (limit || @ledger.size).times do
        entry = @ledger.shift or break
        path, bytes = entry
        body = read(path)
        if body.nil?
          @bytes -= bytes
          next
        end

        delivered = false
        begin
          delivered = yield(body)
        ensure
          @ledger.unshift(entry) unless delivered
        end
        break unless delivered

        @bytes -= bytes
        delete(path)
      end
    end

    def empty?
      @ledger.empty?
    end

    # Take over batches left behind by processes that are gone: up to ADOPTION_CHUNK from every
    # sibling directory whose lock can be taken, and as many from the top level, where versions that
    # shared one directory left theirs. Symlinks are never followed. Returns whether anything was
    # adopted.
    def adopt_orphans
      before = @ledger.size
      ::Dir.glob(::File.join(@root, "*", "lock")).each do |lock_path|
        orphan = ::File.dirname(lock_path)
        adopt(orphan, lock_path) unless orphan == @dir || ::File.symlink?(orphan)
      end
      legacy = regular_files(::Dir.glob(::File.join(@root, "*.batch{,.sending}")))
      take(oldest_first(legacy).first(ADOPTION_CHUNK), @root)
      @ledger.size > before
    end

    # A forked child inherits the parent's lock: closing our copy leaves the parent's intact.
    def detach
      @lock.close
    end

    def close
      ::FileUtils.rm_rf(@dir) if @ledger.empty?
      @lock.close
    end

    private

    # The directory is built under a dot-prefixed name, which the orphan glob does not match, and
    # renamed into place only once its lock is held: a sibling that found it unlocked in between
    # would take it for a dead process's leftovers and remove it.
    def claim_directory
      name = SecureRandom.hex(8)
      staging = ::File.join(@root, ".#{name}")
      ::Dir.mkdir(staging)
      @lock = ::File.open(::File.join(staging, "lock"), ::File::RDWR | ::File::CREAT)
      @lock.flock(::File::LOCK_EX)
      dir = ::File.join(@root, name)
      ::File.rename(staging, dir)
      dir
    end

    # The directory is removed once its last batch is taken; until then other workers take their
    # share, and a torn `.tmp` a crash left behind goes with the directory, never to the drain.
    def adopt(orphan, lock_path)
      lock = ::File.open(lock_path, ::File::RDWR)
      return unless lock.flock(::File::LOCK_EX | ::File::LOCK_NB)

      files = oldest_first(regular_files(::Dir.glob(::File.join(orphan, "*.batch"))))
      taken = take(files.first(ADOPTION_CHUNK), orphan)
      ::FileUtils.rm_rf(orphan) if taken && files.size <= ADOPTION_CHUNK
    rescue Errno::ENOENT
      nil # another process adopted it first
    ensure
      lock&.close
    end

    # Move files into our directory. Rename keeps the mtime, so whoever adopts our directory later
    # still sees their true age. Returns false when a file could not be moved, so that the caller
    # leaves the rest where it is.
    def take(paths, from)
      paths.each do |path|
        dest = next_path
        begin
          ::File.rename(path, dest)
        rescue Errno::ENOENT
          # A batch that is still there could not be moved because our own directory is gone; one
          # that is not was taken by a sibling first.
          raise if ::File.exist?(path)
          next
        end
        bytes = ::File.size(dest)
        @ledger << [dest, bytes]
        @bytes += bytes
      end
      evict(0)
      true
    rescue SystemCallError => e
      safe_warn "Onlylogs::Spool: cannot adopt #{from} (#{e.class}: #{e.message}), leaving it for a later attempt"
      false
    end

    def regular_files(paths)
      paths.reject { |path| ::File.symlink?(path) }
    end

    def oldest_first(paths)
      paths.sort_by { |path| [mtime(path), path] }
    end

    def mtime(path)
      ::File.mtime(path)
    rescue Errno::ENOENT
      Time.at(0)
    end

    def next_path
      ::File.join(@dir, format("%09d.batch", @seq += 1))
    end

    # Not every platform has O_NOFOLLOW; where it exists a symlink that slipped past the listing
    # fails to open instead of being read through.
    NOFOLLOW = ::File.const_defined?(:NOFOLLOW) ? ::File::NOFOLLOW : 0

    def read(path)
      ::File.open(path, ::File::RDONLY | ::File::BINARY | NOFOLLOW, &:read)
    rescue SystemCallError => e
      safe_warn "Onlylogs::Spool: cannot read #{path} (#{e.class}: #{e.message}), skipping it"
      nil
    end

    def delete(path)
      ::File.delete(path)
    rescue Errno::ENOENT
      nil
    rescue SystemCallError => e
      safe_warn "Onlylogs::Spool: cannot delete #{path} (#{e.class}: #{e.message}), it will be sent again after a restart"
    end

    # Delete oldest batches until `incoming` more bytes fit under the cap.
    def evict(incoming)
      while @bytes + incoming > @max_bytes && (oldest = @ledger.shift)
        path, bytes = oldest
        delete(path)
        @bytes -= bytes
      end
    end

    # Kernel.warn itself raises on a closed or detached $stderr, and that must not escape the
    # sender thread.
    def safe_warn(message)
      Kernel.warn(message)
    rescue
      nil
    end
  end
end
