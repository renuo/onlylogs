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
    assert_equal [ 2, "[DEBUG] Initializing database connection - Line 2" ], lines.first
    assert_equal [ 98, "[DEBUG] Application metrics - Line 98" ], lines.last
  end

  test_both_engine_modes "it can grep a simple string in a log file and yield each returned line" do |engine_name|
    lines = []
    Onlylogs::Grep.grep("[DEBUG]", @fixture_path) do |line_number, content|
      lines << [ line_number, content ]
    end
    assert_equal 49, lines.length, "Failed with #{engine_name}"
    assert_equal [ 2, "[DEBUG] Initializing database connection - Line 2" ], lines.first
    assert_equal [ 98, "[DEBUG] Application metrics - Line 98" ], lines.last
  end

  test_both_engine_modes "it returns all INFO lines" do |engine_name|
    lines = Onlylogs::Grep.grep("[INFO]", @fixture_path)
    assert_equal 50, lines.length, "Failed with #{engine_name}"
    assert_equal [ 1, "[INFO] Application started - Line 1" ], lines.first
    assert_equal [ 99, "[INFO] Metrics collected: 150 data points - Line 99" ], lines.last
  end

  test_both_engine_modes "it can grep a string when the line contains ansi colors" do |engine_name|
    expected_line = "\e[1m\e[36mActiveRecord::SchemaMigration Load (0.0ms)\e[0m  \e[1m\e[34mSELECT ...\e[0m"
    lines = Onlylogs::Grep.grep("(0.0ms) SELECT", @special_lines_path)
    assert_equal [ [ 2, expected_line ] ], lines, "Failed with #{engine_name}"
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
end
