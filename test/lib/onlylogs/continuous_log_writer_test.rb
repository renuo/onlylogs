# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "tempfile"
require "onlylogs/continuous_log_writer"

module Onlylogs
  class ContinuousLogWriterTest < ActiveSupport::TestCase
    LINE = /\A\[[0-9a-f-]{36}\] \[\S+\] \[[IWE]\] method=\S+ path=\S+ format=\S+ /

    def setup
      @file = Tempfile.new(["continuous_log_writer", ".log"])
      @path = @file.path
      @writer = Onlylogs::ContinuousLogWriter.new(@path, out: StringIO.new)
    end

    def teardown
      @file.close!
    end

    test "builds a line in the onlylogs format" do
      assert_match LINE, @writer.build_line
    end

    test "builds lines the formatter's tags can be read back from" do
      _request_id, timestamp, severity = @writer.build_line.scan(/\[([^\]]*)\]/).flatten

      assert_nothing_raised { Time.iso8601(timestamp) }
      assert_includes %w[I W E], severity
    end

    test "severity matches the status" do
      lines = 200.times.map { @writer.build_line }

      lines.each do |line|
        status = line[/status=(\d+)/, 1].to_i
        severity = line[/\] \[([IWE])\] /, 1]

        assert_equal status >= 500 ? "E" : (status >= 400 ? "W" : "I"), severity, line
      end
    end

    test "appends a batch to the file and counts it" do
      writer = Onlylogs::ContinuousLogWriter.new(@path, logs_per_batch: 3, interval: 0, out: StringIO.new)
      writer.stub(:sleep, ->(_) { raise Interrupt }) { writer.call }

      assert_equal 3, writer.counter
      assert_equal 3, File.readlines(@path).size
      assert File.readlines(@path).all? { |line| line.match?(LINE) }
    end

    test "appends to an existing file instead of truncating it" do
      File.write(@path, "already here\n")
      writer = Onlylogs::ContinuousLogWriter.new(@path, interval: 0, out: StringIO.new)
      writer.stub(:sleep, ->(_) { raise Interrupt }) { writer.call }

      assert_equal "already here\n", File.readlines(@path).first
      assert_equal 2, File.readlines(@path).size
    end
  end
end
