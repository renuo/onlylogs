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
  end
end
