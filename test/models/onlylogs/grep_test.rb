require "test_helper"

class Onlylogs::GrepTest < ActiveSupport::TestCase
  def setup
    @fixture_path = ::File.expand_path("../../fixtures/files/log_file_100_lines.txt", __dir__)
  end

  test "it can grep for a simple string in a log file" do
    result = Onlylogs::Grep.grep("[DEBUG]", @fixture_path)
    assert_equal 49, result.length
    assert_equal [ 2, "[DEBUG] Initializing database connection - Line 2" ], result.first
    assert_equal [ 98, "[DEBUG] Application metrics - Line 98" ], result.last
  end

  test "it returns all INFO lines" do
    result = Onlylogs::Grep.grep("[INFO]", @fixture_path)
    assert_equal 50, result.length
    assert_equal [ 1, "[INFO] Application started - Line 1" ], result.first
    assert_equal [ 99, "[INFO] Metrics collected: 150 data points - Line 99" ], result.last
  end


  test "it can grep on the first 25% of the file" do
    result = Onlylogs::Grep.grep("[DEBUG]", @fixture_path, start_position: 0, end_position: 25)
    assert_equal 20, result.length
  end

  test "it can grep a string when the line contains ansi colors" do
    # Create a temporary file with ANSI colors for this test
    temp_file = ::File.join(::File.dirname(@fixture_path), "temp_ansi_test.log")
    # Write a line similar to a Rails log line with ANSI colors
    # Example: "\e[1m\e[36mActiveRecord::SchemaMigration Load (0.0ms)\e[0m  \e[1m\e[34mSELECT ...\e[0m"
    line = "\e[1m\e[36mActiveRecord::SchemaMigration Load (0.0ms)\e[0m  \e[1m\e[34mSELECT ...\e[0m"
    ::File.write(temp_file, line)

    result = Onlylogs::Grep.grep("(0.0ms) SELECT", temp_file)
    assert_equal [ [ 1, line ] ], result

    # Clean up the temporary file
    ::File.delete(temp_file) if ::File.exist?(temp_file)
  end


  test "it returns empty array when no matches found" do
    result = Onlylogs::Grep.grep("NONEXISTENT_PATTERN", @fixture_path)
    assert_equal [], result
  end



  test "match_line? matches a single line via regular expression" do
    assert Onlylogs::Grep.match_line?("[INFO] Application started - Line 1", "INFO")
    assert Onlylogs::Grep.match_line?("[INFO] Application started - Line 1", "[INFO]")
    assert Onlylogs::Grep.match_line?("[INFO] Application started - Line 1", "[INFO] Application")
    assert Onlylogs::Grep.match_line?("\e[1m\e[36mActiveRecord::SchemaMigration Load (0.0ms)\e[0m  \e[1m\e[34mSELECT ...\e[0m", "(0.0ms) SELECT")
  end
end
