# frozen_string_literal: true

require "test_helper"
require "stringio"

module Onlylogs
  class SocketLoggerTest < ActiveSupport::TestCase
    setup do
      @sidecars = []
      @loggers = []
    end

    teardown do
      @loggers.each do |logger|
        logger.close
      rescue
        nil
      end
      @sidecars.each(&:close)
    end

    test "sends log lines to the sidecar socket" do
      sidecar = build_sidecar
      logger = build_logger(sidecar)

      logger.add(Logger::INFO, "hello sidecar")
      sleep 0.1

      assert_includes sidecar.received, "hello sidecar"
    end

    # The level must gate the socket, not only the local $stdout fallback. #add writes to the
    # socket before delegating to super (where ::Logger#add checks the level), so without an
    # explicit guard every DEBUG line is shipped to onlylogs.io even at level INFO — this is what
    # floods a production drain with Sentry's `[Transport]`/`[Tracing]` debug output.
    test "does not send lines below the configured level to the socket" do
      sidecar = build_sidecar
      logger = build_logger(sidecar)
      logger.level = Logger::INFO

      logger.add(Logger::DEBUG, "debug below threshold")
      logger.add(Logger::INFO, "info above threshold")
      sleep 0.1

      assert_includes sidecar.received, "info above threshold"
      refute_includes sidecar.received, "debug below threshold",
        "a DEBUG line was shipped to the socket even though the level is INFO"
    end

    private

    def build_sidecar
      MockSidecar.new.tap { |sidecar| @sidecars << sidecar }
    end

    def build_logger(sidecar)
      Onlylogs::SocketLogger.new(local_fallback: StringIO.new, socket_path: sidecar.path)
        .tap { |logger| @loggers << logger }
    end
  end
end
