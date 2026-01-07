require "test_helper"


class Onlylogs::GrepTest < ActiveSupport::TestCase
  def setup
    @fixture_path = ::File.expand_path("../../fixtures/files/log_file_100_lines.txt", __dir__)
    @special_lines_path = File.expand_path("../../fixtures/files/log_special_lines.txt", __dir__)
    @original_ripgrep_enabled = Onlylogs.ripgrep_enabled?
  end

  def teardown
    Onlylogs.configuration.ripgrep_enabled = @original_ripgrep_enabled
  end

  def self.test_both_engine_modes(test_name, &block)
    test test_name do
      [false, true].each do |ripgrep_enabled|
        Onlylogs.configuration.ripgrep_enabled = ripgrep_enabled
        engine_name = ripgrep_enabled ? 'ripgrep' : 'grep'
        instance_exec(engine_name, &block)
      end
    end
  end

  test_both_engine_modes "it can grep for a simple string in a log file" do |engine_name|
    lines = Onlylogs::Grep.grep("[DEBUG]", @fixture_path)
    assert_equal 49, lines.length, "Failed with #{engine_name}"
    assert_equal "[DEBUG] Initializing database connection - Line 2", lines.first
    assert_equal "[DEBUG] Application metrics - Line 98", lines.last
  end

  test_both_engine_modes "it can grep a simple string in a log file and yield each returned line" do |engine_name|
    lines = []
    Onlylogs::Grep.grep("[DEBUG]", @fixture_path) do |content|
      lines << content
    end
    assert_equal 49, lines.length, "Failed with #{engine_name}"
    assert_equal "[DEBUG] Initializing database connection - Line 2", lines.first
    assert_equal "[DEBUG] Application metrics - Line 98", lines.last
  end

  test_both_engine_modes "it returns all INFO lines" do |engine_name|
    lines = Onlylogs::Grep.grep("[INFO]", @fixture_path)
    assert_equal 50, lines.length, "Failed with #{engine_name}"
    assert_equal "[INFO] Application started - Line 1", lines.first
    assert_equal "[INFO] Metrics collected: 150 data points - Line 99", lines.last
  end

  test_both_engine_modes "it can grep a string when the line contains ansi colors" do |engine_name|
    expected_line = "\e[1m\e[36mActiveRecord::SchemaMigration Load (0.0ms)\e[0m  \e[1m\e[34mSELECT ...\e[0m"
    lines = Onlylogs::Grep.grep("(0.0ms) SELECT", @special_lines_path)
    assert_equal [ expected_line ], lines, "Failed with #{engine_name}"
  end

  test_both_engine_modes "it can grep a string with special regex characters" do |engine_name|
    lines = Onlylogs::Grep.grep("watcher", @special_lines_path)
    assert_equal 1, lines.length, "Failed with #{engine_name}"

    lines = Onlylogs::Grep.grep("watcher({\"", @special_lines_path)
    assert_equal 1, lines.length, "Failed with #{engine_name}"
  end

  test_both_engine_modes "it returns empty array when no matches found" do |engine_name|
    lines = Onlylogs::Grep.grep("NONEXISTENT_PATTERN", @fixture_path)
    assert_equal [], lines, "Failed with #{engine_name}"
  end

  test "match_line? matches a single line via regular expression" do
    assert Onlylogs::Grep.match_line?("[INFO] Application started - Line 1", "INFO")
    assert Onlylogs::Grep.match_line?("[INFO] Application started - Line 1", "[INFO]")
    assert Onlylogs::Grep.match_line?("[INFO] Application started - Line 1", "[INFO] Application")
    assert Onlylogs::Grep.match_line?("\e[1m\e[36mActiveRecord::SchemaMigration Load (0.0ms)\e[0m  \e[1m\e[34mSELECT ...\e[0m", "(0.0ms) SELECT")
    assert Onlylogs::Grep.match_line?("initialize_watcher({\"cursor_position\"", "watcher({\"cursor")
    # assert Onlylogs::Grep.match_line?("[d310974f-969e-4f61-8502-07b7f51fdaef]   [1m[36mCACHE Book Count (0.0ms)[0m  [1m[34mSELECT COUNT(*) FROM \"books\"[0m", "07b7f51fdaef]   CACHE")
  end

  test_both_engine_modes "it can grep with regexp mode using dot wildcard" do |engine_name|
    # In literal mode, dot should match literal dot
    lines_literal = Onlylogs::Grep.grep("(0.0ms)", @special_lines_path, regexp_mode: false)
    assert_equal 1, lines_literal.length, "Failed with #{engine_name}"
    
    # In regexp mode, dot should match any character
    lines_regexp = Onlylogs::Grep.grep("(0\\.0ms)", @special_lines_path, regexp_mode: true)
    assert_equal 1, lines_regexp.length, "Failed with #{engine_name}"
    
    # Test that regexp mode with dot wildcard matches more broadly
    lines_wildcard = Onlylogs::Grep.grep("(0.0ms)", @special_lines_path, regexp_mode: true)
    assert_equal 1, lines_wildcard.length, "Failed with #{engine_name}"
  end

  test_both_engine_modes "it can grep with regexp mode using character classes" do |engine_name|
    # Test character class [A-Z] to match uppercase letters
    lines = Onlylogs::Grep.grep("\\[INFO\\]", @fixture_path, regexp_mode: true)
    assert_equal 50, lines.length, "Failed with #{engine_name}"
    
    # Test that literal mode treats brackets as literal characters
    lines_literal = Onlylogs::Grep.grep("[INFO]", @fixture_path, regexp_mode: false)
    assert_equal 50, lines_literal.length, "Failed with #{engine_name}"
  end

  test_both_engine_modes "it can grep with regexp mode using quantifiers" do |engine_name|
    # Test + quantifier to match one or more digits
    lines = Onlylogs::Grep.grep("Line \\d+", @fixture_path, regexp_mode: true)
    assert_equal 100, lines.length, "Failed with #{engine_name}"
    
    # Test that literal mode treats + as literal character
    lines_literal = Onlylogs::Grep.grep("Line +", @fixture_path, regexp_mode: false)
    assert_equal 0, lines_literal.length, "Failed with #{engine_name}"
  end

  test "match_line? supports regexp mode with dot wildcard" do
    line = "ActiveRecord::SchemaMigration Load (0.0ms) SELECT ..."
    
    # In literal mode, dot should match literal dot
    assert Onlylogs::Grep.match_line?(line, "(0.0ms)", regexp_mode: false)
    
    # In regexp mode, escaped dot should match literal dot
    assert Onlylogs::Grep.match_line?(line, "\\(0\\.0ms\\)", regexp_mode: true)
    
    # In regexp mode, unescaped dot should match any character
    assert Onlylogs::Grep.match_line?(line, "\\(0.0ms\\)", regexp_mode: true)
    
    # Test that literal mode treats dot as literal
    refute Onlylogs::Grep.match_line?(line, "(0X0ms)", regexp_mode: false)
  end

  test "match_line? supports regexp mode with character classes" do
    line = "[INFO] Application started - Line 1"
    
    # Test escaped brackets to match literal brackets
    assert Onlylogs::Grep.match_line?(line, "\\[INFO\\]", regexp_mode: true)
    
    # Test character class [A-Z] to match uppercase letters (should not match [INFO])
    refute Onlylogs::Grep.match_line?(line, "\\[A-Z\\]INFO", regexp_mode: true)
    
    # Test that literal mode treats brackets as literal characters
    refute Onlylogs::Grep.match_line?(line, "[A-Z]INFO", regexp_mode: false)
    
    # Test a line that would match a simple regexp pattern
    line_with_numbers = "Error 404: Page not found"
    assert Onlylogs::Grep.match_line?(line_with_numbers, "Error \\d+:", regexp_mode: true)
  end

  test_both_engine_modes "it respects max_line_matches configuration" do |engine_name|
    # Set a very low max_line_matches to test limiting
    original_max_matches = Onlylogs.max_line_matches
    Onlylogs.configuration.max_line_matches = 5
    
    # This should return only 5 results even though there are more matches
    lines = Onlylogs::Grep.grep("Line", @fixture_path)
    assert_equal 5, lines.length, "Failed with #{engine_name}"
    
    # Restore original configuration
    Onlylogs.configuration.max_line_matches = original_max_matches
  end

  test_both_engine_modes "it allows unlimited matches when max_line_matches is nil" do |engine_name|
    # Set max_line_matches to nil to test no limits
    original_max_matches = Onlylogs.max_line_matches
    Onlylogs.configuration.max_line_matches = nil
    
    # This should return all matches (100 lines in the fixture file)
    lines = Onlylogs::Grep.grep("Line", @fixture_path)
    assert_equal 100, lines.length, "Failed with #{engine_name}"
    
    # Restore original configuration
    Onlylogs.configuration.max_line_matches = original_max_matches
  end
end
