# frozen_string_literal: true

require "test_helper"

module Onlylogs
  class LocalFallbackTest < ActiveSupport::TestCase
    setup do
      @log_dir = Rails.root.join("tmp", "test_local_fallback")
      FileUtils.mkdir_p(@log_dir)
      @log_file = @log_dir.join("test.log")
    end

    teardown do
      FileUtils.rm_rf(@log_dir)
    end

    test "BroadcastLogger with HttpLogger writes to local file and queues for remote" do
      local = Onlylogs::Logger.new(@log_file.to_s, 5, 100.megabytes)
      remote = Onlylogs::HttpLogger.new(drain_url: nil)
      logger = ActiveSupport::BroadcastLogger.new(local, remote)

      logger.info("broadcast http line")

      content = ::File.read(@log_file)
      assert_includes content, "broadcast http line"
    end

    test "BroadcastLogger with SocketLogger writes to local file and forwards to socket" do
      local = Onlylogs::Logger.new(@log_file.to_s, 5, 100.megabytes)
      remote = Onlylogs::SocketLogger.new(socket_path: "/tmp/nonexistent.sock")
      logger = ActiveSupport::BroadcastLogger.new(local, remote)

      logger.info("broadcast socket line")

      content = ::File.read(@log_file)
      assert_includes content, "broadcast socket line"
    end

    test "BroadcastLogger local file supports log rotation" do
      local = Onlylogs::Logger.new(@log_file.to_s, 2, 50)
      remote = Onlylogs::HttpLogger.new(drain_url: nil)
      logger = ActiveSupport::BroadcastLogger.new(local, remote)

      20.times { |i| logger.info("rotation line #{i} with some padding to fill up space") }

      rotated_files = Dir.glob("#{@log_file}*")
      assert rotated_files.size > 1, "Expected rotated log files, got: #{rotated_files}"
    end
  end
end
