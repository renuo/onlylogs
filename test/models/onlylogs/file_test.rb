require "test_helper"

class Onlylogs::FileTest < ActiveSupport::TestCase
  def setup
    @fixture_path = File.expand_path("../../fixtures/files/log_file_100_lines.txt", __dir__)
    @log_file = Onlylogs::File.new(@fixture_path)
  end

  test "initializes with default last_position of 0" do
    assert_equal 0, @log_file.last_position
  end

  test "initializes with custom last_position" do
    @log_file = Onlylogs::File.new(@fixture_path, last_position: 100)
    assert_equal 100, @log_file.last_position
  end



  test "raises error during initialization when file does not exist" do
    assert_raises(Onlylogs::Error, /File not found/) do
      Onlylogs::File.new("/path/to/nonexistent/file.log")
    end
  end

  test "go_to_position sets the position correctly" do
    test_file_path = File.expand_path("../../fixtures/files/test_go_to_position.txt", __dir__)
    File.write(test_file_path, "Line 0\nLine 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10\n")

    begin
      test_file = Onlylogs::File.new(test_file_path, last_position: 0)
      # Go to position after line 3 (which should be after "Line 3\n")
      position_after_line_3 = "Line 0\nLine 1\nLine 2\nLine 3\n".bytesize
      test_file.go_to_position(position_after_line_3)
      assert_equal position_after_line_3, test_file.last_position
      result = test_file.send(:read_new_lines)
      expected = ["Line 4", "Line 5", "Line 6", "Line 7", "Line 8", "Line 9", "Line 10"]
      assert_equal expected, result
    ensure
      File.delete(test_file_path) if File.exist?(test_file_path)
    end
  end

  test "read_new_lines returns new lines when file has new content" do
    test_file_path = File.expand_path("../../fixtures/files/test_read_new_lines.txt", __dir__)
    File.write(test_file_path, "Line 0\nLine 1\nLine 2\n")

    begin
      test_file = Onlylogs::File.new(test_file_path, last_position: 0)
      result = test_file.send(:read_new_lines)

      expected = ["Line 0", "Line 1", "Line 2"]
      assert_equal expected, result
      assert_equal 21, test_file.last_position # "Line 0\nLine 1\nLine 2\n".bytesize

      File.open(test_file_path, "a") do |f|
        f.puts "Line 3"
        f.puts "Line 4"
        f.puts "Line 5"
        f.puts "Line 6"
      end

      result = test_file.send(:read_new_lines)
      expected = ["Line 3", "Line 4", "Line 5", "Line 6"]
      assert_equal expected, result

      File.open(test_file_path, "a") do |f|
        f.puts "Line 7"
        f.puts "Line 8"
        f.write "Incomplete"
      end

      result = test_file.send(:read_new_lines)
      expected = ["Line 7", "Line 8"]
      assert_equal expected, result

      File.open(test_file_path, "a") do |f|
        f.write " Line 9\n"
        f.puts "Line 10"
        f.puts "Line 11"
      end

      # Should return the completed line plus the 2 new lines
      result = test_file.send(:read_new_lines)
      expected = ["Incomplete Line 9", "Line 10", "Line 11"]
      assert_equal expected, result
    ensure
      File.delete(test_file_path) if File.exist?(test_file_path)
    end
  end

  test "text_file? returns true for text files" do
    assert @log_file.text_file?
  end

  test "text_file? returns false for non-existent files" do
    refute Onlylogs::File.text_file?("/path/to/nonexistent/file.log")
  end

  test "text_file? returns false for empty files" do
    test_file_path = File.expand_path("../../fixtures/files/test_empty.txt", __dir__)
    File.write(test_file_path, "")

    begin
      refute Onlylogs::File.text_file?(test_file_path)
    ensure
      File.delete(test_file_path) if File.exist?(test_file_path)
    end
  end

  test "text_file? returns false for files with null bytes" do
    test_file_path = File.expand_path("../../fixtures/files/test_binary.bin", __dir__)
    File.write(test_file_path, "Some text\x00binary content")

    begin
      refute Onlylogs::File.text_file?(test_file_path)
    ensure
      File.delete(test_file_path) if File.exist?(test_file_path)
    end
  end

  test "text_file? returns false for gzipped files" do
    require "zlib"

    test_file_path = File.expand_path("../../fixtures/files/test.log.gz", __dir__)

    # Create an actual gzipped file
    Zlib::GzipWriter.open(test_file_path) do |gz|
      gz.write "This is a log line\n"
      gz.write "This is another log line\n"
    end

    begin
      refute Onlylogs::File.text_file?(test_file_path), "Expected gzipped file to be detected as non-text"
    ensure
      File.delete(test_file_path) if File.exist?(test_file_path)
    end
  end
end
