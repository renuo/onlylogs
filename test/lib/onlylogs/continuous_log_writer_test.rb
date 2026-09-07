# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "onlylogs/continuous_log_writer"

module Onlylogs
  class ContinuousLogWriterTest < ActiveSupport::TestCase
    LINE = /\A\[[0-9a-f-]{36}\] \[\S+\] \[[IDWF]\] /

    # `call` loops forever; interrupting the first sleep stops it after one batch.
    class SingleBatchWriter < Onlylogs::ContinuousLogWriter
      private

      def sleep(_seconds)
        raise Interrupt
      end
    end

    def setup
      @file = Tempfile.new(["continuous_log_writer", ".log"])
      @path = @file.path
      @writer = Onlylogs::ContinuousLogWriter.new(@path, out: StringIO.new)
    end

    def teardown
      @file.close!
    end

    test "builds a full request in the onlylogs format" do
      lines = @writer.build_request_lines(status: 200)

      assert lines.all? { |line| line.match?(LINE) }, lines.join("\n")
      assert_match(/Started (GET|POST) "/, lines.first)
      assert(lines.any? { |line| line.include?("Processing by") })
      assert(lines.any? { |line| line.include?("Completed 200 OK in") })
    end

    test "builds lines the formatter's tags can be read back from" do
      request_id, timestamp, severity = @writer.build_request_lines.first.scan(/\[([^\]]*)\]/).flatten

      assert_match(/\A[0-9a-f-]{36}\z/, request_id)
      assert_nothing_raised { Time.iso8601(timestamp) }
      assert_includes %w[I D W F], severity
    end

    test "tags every line of a request with the same request id" do
      lines = @writer.build_request_lines

      assert_equal 1, lines.map { |line| line[/\A\[([^\]]*)\]/, 1] }.uniq.size
    end

    test "colors SQL lines with ANSI codes the viewer can parse" do
      lines = @writer.build_request_lines(status: 200)
      sql_lines = lines.select { |line| line.include?("SELECT") }

      assert sql_lines.any?
      sql_lines.each do |line|
        assert_match(/\e\[1m\e\[3\dm.*\e\[0m/, line)
      end
    end

    test "logs a red fatal exception on 500s" do
      lines = @writer.build_request_lines(status: 500)

      assert(lines.any? { |line| line.include?("Completed 500 Internal Server Error") })
      assert(lines.any? { |line| line.match?(/\[F\] \e\[1m\e\[31mNoMethodError/) })
    end

    test "appends a batch to the file and counts the lines" do
      writer = SingleBatchWriter.new(@path, logs_per_batch: 3, interval: 0, out: StringIO.new)
      writer.call

      lines = ::File.readlines(@path)
      assert_equal lines.size, writer.counter
      assert_equal 3, lines.grep(/Started /).size
      assert lines.all? { |line| line.match?(LINE) }
    end

    test "appends to an existing file instead of truncating it" do
      ::File.write(@path, "already here\n")
      writer = SingleBatchWriter.new(@path, interval: 0, out: StringIO.new)
      writer.call

      assert_equal "already here\n", ::File.readlines(@path).first
      assert_operator ::File.readlines(@path).size, :>, 1
    end
  end
end
