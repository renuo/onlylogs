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
  end
end
