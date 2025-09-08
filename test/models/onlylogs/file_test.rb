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
    @log_file = Onlylogs::FastFile.new(@fixture_path, last_position: 100)
    assert_equal 100, @log_file.last_position
  end

  test "calculates the initial line number correctly" do
    assert_equal 0, @log_file.last_line_number
  end

  test "calculates the line number at position correctly" do
    @log_file.go_to_position(300)
    assert_equal 5, @log_file.last_line_number
  end

  test "calculates the line number efficiently on a big file" do
    big_file = Onlylogs::File.new(File.expand_path("../../fixtures/files/big.log", __dir__))
    start_time = Time.now
    big_file.go_to_position(835_436_842)
    end_time = Time.now
    assert_equal 1434016, big_file.last_line_number
    assert_in_delta 3.0, end_time - start_time, 3.0
  end


  test "raises error during initialization when file does not exist" do
    assert_raises(Onlylogs::Error, /File not found/) do
      Onlylogs::File.new("/path/to/nonexistent/file.log")
    end
  end

  test "go_to_position sets the position and calculates line number correctly" do
    test_file_path = File.expand_path("../../fixtures/files/test_go_to_position.txt", __dir__)
    File.write(test_file_path, "Line 0\nLine 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10\n")

    begin
      test_file = Onlylogs::File.new(test_file_path, last_position: 0)
      # Go to position after line 3 (which should be after "Line 3\n")
      position_after_line_3 = "Line 0\nLine 1\nLine 2\nLine 3\n".bytesize
      test_file.go_to_position(position_after_line_3)
      assert_equal position_after_line_3, test_file.last_position
      result = test_file.send(:read_new_lines).map(&:to_a)
      expected = [
        [ 4, "Line 4" ],
        [ 5, "Line 5" ],
        [ 6, "Line 6" ],
        [ 7, "Line 7" ],
        [ 8, "Line 8" ],
        [ 9, "Line 9" ],
        [ 10, "Line 10" ]
      ]
      assert_equal expected, result
    ensure
      File.delete(test_file_path) if File.exist?(test_file_path)
    end
  end

  test "read_new_lines returns new lines with their line numbers when file has new content" do
    test_file_path = File.expand_path("../../fixtures/files/test_read_new_lines.txt", __dir__)
    File.write(test_file_path, "Line 0\nLine 1\nLine 2\n")

    begin
      test_file = Onlylogs::File.new(test_file_path, last_position: 0)
      result = test_file.send(:read_new_lines).map(&:to_a)

      expected = [
        [ 1, "Line 0" ],
        [ 2, "Line 1" ],
        [ 3, "Line 2" ]
      ]
      assert_equal expected, result
      assert_equal 21, test_file.last_position # "Line 0\nLine 1\nLine 2\n".bytesize

      File.open(test_file_path, "a") do |f|
        f.puts "Line 3"
        f.puts "Line 4"
        f.puts "Line 5"
        f.puts "Line 6"
      end

      result = test_file.send(:read_new_lines).map(&:to_a)
      expected = [
        [ 4, "Line 3" ],
        [ 5, "Line 4" ],
        [ 6, "Line 5" ],
        [ 7, "Line 6" ]
      ]
      assert_equal expected, result

      File.open(test_file_path, "a") do |f|
        f.puts "Line 7"
        f.puts "Line 8"
        f.write "Incomplete"
      end

      result = test_file.send(:read_new_lines).map(&:to_a)
      expected = [
        [ 8, "Line 7" ],
        [ 9, "Line 8" ]
      ]
      assert_equal expected, result

      File.open(test_file_path, "a") do |f|
        f.write " Line 9\n"
        f.puts "Line 10"
        f.puts "Line 11"
      end

      # Should return the completed line plus the 2 new lines
      result = test_file.send(:read_new_lines).map(&:to_a)
      expected = [
        [ 10, "Incomplete Line 9" ],
        [ 11, "Line 10" ],
        [ 12, "Line 11" ]
      ]
      assert_equal expected, result
    ensure
      File.delete(test_file_path) if File.exist?(test_file_path)
    end
  end
end
