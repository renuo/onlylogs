require "test_helper"

class Onlylogs::FastFileTest < ActiveSupport::TestCase
  def setup
    @fixture_path = File.expand_path("../../fixtures/files/log_file_100_lines.txt", __dir__)
    @fast_file = Onlylogs::FastFile.new(@fixture_path)
  end

  test "initializes with default last_position of 0" do
    assert_equal 0, @fast_file.last_position
  end

  test "initializes with custom last_position" do
    @fast_file = Onlylogs::FastFile.new(@fixture_path, last_position: 100)
    assert_equal 100, @fast_file.last_position
  end

  test "go_to_position sets the cursor position" do
    @fast_file.go_to_position(100)
    assert_equal 100, @fast_file.last_position
  end

  test "go_to_position ignores negative positions" do
    original_position = @fast_file.last_position
    @fast_file.go_to_position(-10)
    assert_equal original_position, @fast_file.last_position
  end

  test "go_to_position accepts zero position" do
    @fast_file.go_to_position(0)
    assert_equal 0, @fast_file.last_position
  end

  test "read_new_lines returns new content from cursor position" do
    test_file_path = File.expand_path("../../fixtures/files/test_read_new_lines.txt", __dir__)
    File.write(test_file_path, "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10\n")

    begin
      test_file = Onlylogs::FastFile.new(test_file_path)
      new_lines = test_file.read_new_lines

      assert_equal [ "Line 1", "Line 2", "Line 3", "Line 4", "Line 5", "Line 6", "Line 7", "Line 8", "Line 9", "Line 10" ], new_lines
      assert_equal File.size(test_file_path), test_file.last_position

      File.open(test_file_path, "a") do |f|
        f.puts "Line 11"
        f.puts "Line 12"
      end

      new_lines = test_file.read_new_lines
      assert_equal [ "Line 11", "Line 12" ], new_lines

    ensure
      File.delete(test_file_path) if File.exist?(test_file_path)
    end
  end

  test "read_new_lines from big file" do
    test_file_path = File.expand_path("../../fixtures/files/big.log", __dir__)

    begin
      tail = 100
      test_file = Onlylogs::FastFile.new(test_file_path, last_position: File.size(test_file_path) - (tail * 100))
      test_file
      new_lines = test_file.read_new_lines

      assert_equal 27, new_lines.length

      new_lines = test_file.read_new_lines

      assert_equal [], new_lines
    end
  end

  test "read_new_lines handles incomplete lines correctly" do
    test_file_path = File.expand_path("../../fixtures/files/test_incomplete_lines.txt", __dir__)
    File.write(test_file_path, "Line 1\nLine 2\nIncomplete")

    begin
      test_file = Onlylogs::FastFile.new(test_file_path, last_position: 0)
      new_lines = test_file.read_new_lines

      # Should only return complete lines
      assert_equal [ "Line 1", "Line 2" ], new_lines

      # Complete the line
      File.open(test_file_path, "a") do |f|
        f.write " Line 3\n"
        f.puts "Line 4"
      end

      new_lines = test_file.read_new_lines
      assert_equal [ "Incomplete Line 3", "Line 4" ], new_lines

    ensure
      File.delete(test_file_path) if File.exist?(test_file_path)
    end
  end

  test "read_new_lines returns empty array when no new content" do
    test_file_path = File.expand_path("../../fixtures/files/test_no_new_content.txt", __dir__)
    File.write(test_file_path, "Line 1\nLine 2\n")

    begin
      test_file = Onlylogs::FastFile.new(test_file_path, last_position: File.size(test_file_path))
      new_lines = test_file.read_new_lines

      assert_empty new_lines

    ensure
      File.delete(test_file_path) if File.exist?(test_file_path)
    end
  end
end
