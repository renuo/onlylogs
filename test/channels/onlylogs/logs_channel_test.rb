require "test_helper"

module Onlylogs
  class LogsChannelTest < ActionCable::Channel::TestCase
    setup do
      @temp_file = Tempfile.new("test_log")
      @temp_file.write("line 1\nline 2\nline 3\n")
      @temp_file.close

      allow(Onlylogs).to receive(:file_path_permitted?).and_return(true)
      allow(Onlylogs::SecureFilePath).to receive(:decrypt).and_return(@temp_file.path)
    end

    teardown do
      @temp_file.unlink
    end

    test "clamps negative start_position to 0" do
      subscribe file_path: "encrypted", mode: "static", start_position: -42, end_position: nil
      assert subscribed
    end

    test "clamps start_position exceeding file size" do
      file_size = File.size(@temp_file.path)
      subscribe file_path: "encrypted", mode: "static", start_position: file_size + 1000, end_position: nil
      assert subscribed
    end

    test "clamps negative end_position to 0" do
      subscribe file_path: "encrypted", mode: "static", start_position: 0, end_position: -50
      assert subscribed
    end

    test "clamps end_position exceeding file size" do
      file_size = File.size(@temp_file.path)
      subscribe file_path: "encrypted", mode: "static", start_position: 0, end_position: file_size + 1000
      assert subscribed
    end

    test "accepts valid positions" do
      file_size = File.size(@temp_file.path)
      subscribe file_path: "encrypted", mode: "static", start_position: 0, end_position: file_size
      assert subscribed
    end

    # Expand-around-line feature tests

    test "render_log_line includes byte_offset for static searches" do
      channel = LogsChannel.new(connection, {})
      line = "test log line"
      result = channel.send(:render_log_line, line, byte_offset: 1000, show_expand_button: true)

      assert result.is_a?(Hash)
      assert_equal 1000, result[:byte_offset]
      assert_equal true, result[:show_expand_button]
      assert result[:content].present?
    end

    test "render_log_line omits byte_offset and show_expand_button for live mode" do
      channel = LogsChannel.new(connection, {})
      line = "test log line"
      result = channel.send(:render_log_line, line)

      assert result.is_a?(Hash)
      assert_nil result[:byte_offset]
      assert_nil result[:show_expand_button]
      assert result[:content].present?
    end
  end
end
