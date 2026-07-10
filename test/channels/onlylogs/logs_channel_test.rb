# frozen_string_literal: true

require "test_helper"

module Onlylogs
  class LogsChannelTest < ActionCable::Channel::TestCase
    setup do
      @temp_file = Tempfile.new(["test_log", ".log"])
      @temp_file.write("line 1\nline 2\nline 3\n")
      @temp_file.close

      # Configure the engine to permit the temp file so no mocking is needed.
      Onlylogs.instance_variable_set(:@configuration, nil)
      Onlylogs.configure do |config|
        config.log_file_patterns = [@temp_file.path]
      end

      @file_size = ::File.size(@temp_file.path)
      @encrypted_path = Onlylogs::SecureFilePath.encrypt(@temp_file.path)
    end

    teardown do
      @temp_file.unlink
      Onlylogs.instance_variable_set(:@configuration, nil)
    end

    # `initialize_watcher` clamps start/end positions into [0, file_size] before
    # reading. Out-of-range positions must not raise and must still complete the
    # search with a "finish" transmission.

    test "clamps negative start_position and still finishes" do
      subscribe
      perform :initialize_watcher, initialize_data(start_position: -42)

      assert_equal "finish", transmissions.last["action"]
    end

    test "clamps start_position exceeding file size and still finishes" do
      subscribe
      perform :initialize_watcher, initialize_data(start_position: @file_size + 1000)

      assert_equal "finish", transmissions.last["action"]
    end

    test "clamps negative end_position and still finishes" do
      subscribe
      perform :initialize_watcher, initialize_data(end_position: -50)

      assert_equal "finish", transmissions.last["action"]
    end

    test "clamps end_position exceeding file size and still finishes" do
      subscribe
      perform :initialize_watcher, initialize_data(end_position: @file_size + 1000)

      assert_equal "finish", transmissions.last["action"]
    end

    test "reads the whole file for valid positions" do
      subscribe
      perform :initialize_watcher, initialize_data(start_position: 0, end_position: @file_size)

      assert_equal "finish", transmissions.last["action"]
    end

    test "denies access to a non-permitted file" do
      subscribe
      encrypted_bad = Onlylogs::SecureFilePath.encrypt("/etc/passwd")
      perform :initialize_watcher, initialize_data(file_path: encrypted_bad)

      error = transmissions.find { |t| t["action"] == "error" }
      assert error, "expected an error transmission for a non-permitted file"
      assert_equal "Access denied", error["content"]
    end

    # Expand-around-line feature tests

    test "render_log_line includes byte_offset and expand button for static searches" do
      subscribe
      result = subscription.send(:render_log_line, "test log line", byte_offset: 1000, show_expand_button: true)

      assert result.is_a?(Hash)
      assert_equal 1000, result[:byte_offset]
      assert_equal true, result[:show_expand_button]
      assert result[:content].present?
    end

    test "render_log_line omits byte_offset and expand button for live mode" do
      subscribe
      result = subscription.send(:render_log_line, "test log line")

      assert result.is_a?(Hash)
      assert_nil result[:byte_offset]
      assert_equal false, result[:show_expand_button]
      assert result[:content].present?
    end

    private

    def initialize_data(overrides = {})
      {file_path: @encrypted_path, mode: "static", start_position: 0, end_position: nil}.merge(overrides)
    end
  end
end
