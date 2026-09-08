# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

module Onlylogs
  class SpoolTest < ActiveSupport::TestCase
    setup do
      @dir = ::Dir.mktmpdir
      @spool = Onlylogs::Spool.new(dir: @dir)
    end

    teardown do
      ::File.chmod(0o755, @dir) if ::File.directory?(@dir)
      ::FileUtils.remove_entry(@dir) if ::File.directory?(@dir)
    end

    test "writes a batch and replays it, deleting the file once delivered" do
      @spool.write("hello\nworld")

      replayed = []
      @spool.replay do |body|
        replayed << body
        true
      end

      assert_equal ["hello\nworld"], replayed
      assert @spool.empty?, "the spool should be empty after a successful replay"
    end

    test "ignores blank batches" do
      @spool.write(nil)
      @spool.write("")

      assert @spool.empty?
    end

    test "keeps the batch on disk when delivery fails, and delivers it on a later replay" do
      @spool.write("keep me")

      @spool.replay { |_body| false }
      refute @spool.empty?, "a failed delivery must not delete the spooled batch"

      delivered = []
      @spool.replay do |body|
        delivered << body
        true
      end
      assert_equal ["keep me"], delivered
      assert @spool.empty?
    end

    test "replays oldest-first and stops at the first failure" do
      @spool.write("one")
      @spool.write("two")
      @spool.write("three")

      seen = []
      @spool.replay do |body|
        seen << body
        body != "two" # fail on "two"
      end

      # Stopped at "two"; "one" was delivered and removed, "two"/"three" remain in order.
      assert_equal ["one", "two"], seen

      remaining = []
      @spool.replay do |body|
        remaining << body
        true
      end
      assert_equal ["two", "three"], remaining
    end

    test "replays only the oldest batches when a limit is given, keeping the ledger current" do
      @spool.write("one")
      @spool.write("two")

      seen = []
      @spool.replay(limit: 1) do |body|
        seen << body
        true
      end
      assert_equal ["one"], seen
      refute @spool.empty?

      @spool.replay(limit: 1) do |body|
        seen << body
        true
      end
      assert_equal ["one", "two"], seen
      assert @spool.empty?
    end

    test "rolls the oldest batches off when the byte cap is exceeded" do
      spool = Onlylogs::Spool.new(dir: @dir, max_bytes: 20)

      spool.write("a" * 8) # 8 bytes
      spool.write("b" * 8) # 16 bytes total
      spool.write("c" * 8) # 24 > 20 -> evict the oldest ("a")

      bodies = []
      spool.replay do |body|
        bodies << body
        true
      end
      assert_equal ["b" * 8, "c" * 8], bodies
    end

    # Sibling processes (other Puma workers) share the directory: their files must count towards
    # the cap even though this instance did not write them.
    test "counts batches written by another instance towards the byte cap" do
      sibling = Onlylogs::Spool.new(dir: @dir, max_bytes: 20)
      sibling.write("a" * 8)

      spool = Onlylogs::Spool.new(dir: @dir, max_bytes: 20)
      spool.write("b" * 8) # 16 bytes total, seen via the directory listing
      spool.write("c" * 8) # 24 > 20 -> evict the sibling's "a"

      bodies = []
      spool.replay do |body|
        bodies << body
        true
      end
      assert_equal ["b" * 8, "c" * 8], bodies
    end

    # A file this process cannot claim (wrong owner, read-only volume) could not be deleted after
    # delivery either, so replaying it would re-send the same batch in a tight loop.
    test "skips a batch it cannot claim" do
      skip "root can rename anything" if Process.uid.zero?
      @spool.write("stuck")
      ::File.chmod(0o555, @dir)

      delivered = []
      capture_stderr { 3.times { @spool.replay { |body| delivered << body } } }

      assert_empty delivered
      assert @spool.empty?, "an unclaimable batch should be skipped, not retried forever"
      assert_equal 1, ::Dir.glob(::File.join(@dir, "*.batch")).size
    end

    test "skips a batch it cannot read" do
      skip "root can read anything" if Process.uid.zero?
      @spool.write("unreadable")
      @spool.write("fine")
      ::File.chmod(0o000, ::Dir.glob(::File.join(@dir, "*.batch")).min)

      delivered = []
      capture_stderr { @spool.replay { |body| delivered << body } }

      assert_equal ["fine"], delivered
      assert @spool.empty?
    end

    # Puma workers share the directory: a batch must be delivered by one of them, not by each.
    test "two instances replaying the same directory deliver each batch once" do
      100.times { |i| @spool.write("batch #{i}") }
      sibling = Onlylogs::Spool.new(dir: @dir)

      delivered = []
      until @spool.empty? && sibling.empty?
        [@spool, sibling].each { |spool| spool.replay(limit: 1) { |body| delivered << body } }
      end

      assert_equal 100, delivered.size, "expected each batch once, got #{delivered.tally.select { |_, n| n > 1 }}"
    end

    test "hands a batch back when delivery fails so any worker can retry it" do
      @spool.write("retry me")

      @spool.replay { |_body| false }

      assert_equal 1, ::Dir.glob(::File.join(@dir, "*.batch")).size
      assert_empty ::Dir.glob(::File.join(@dir, "*.sending"))
    end

    test "reclaims a claim left behind by a dead worker, but not a fresh one" do
      @spool.write("abandoned")
      @spool.write("in flight")
      abandoned, in_flight = ::Dir.glob(::File.join(@dir, "*.batch")).sort
      ::File.rename(abandoned, "#{abandoned}.sending")
      ::File.rename(in_flight, "#{in_flight}.sending")
      stale = Time.now - Onlylogs::Spool::STALE_CLAIM_AFTER - 1
      ::File.utime(stale, stale, "#{abandoned}.sending")

      delivered = []
      Onlylogs::Spool.new(dir: @dir).replay do |body|
        delivered << body
        true
      end

      assert_equal ["abandoned"], delivered
    end

    test "a fresh instance replays files left behind by a previous one (survives restart)" do
      @spool.write("survivor")

      reopened = Onlylogs::Spool.new(dir: @dir)
      bodies = []
      reopened.replay do |body|
        bodies << body
        true
      end

      assert_equal ["survivor"], bodies
    end

    private

    def capture_stderr
      original = $stderr
      $stderr = StringIO.new
      yield
    ensure
      $stderr = original
    end
  end
end
