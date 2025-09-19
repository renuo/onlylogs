require "test_helper"


class Onlylogs::GrepTest < ActiveSupport::TestCase
  def setup
    @fixture_path = ::File.expand_path("../../fixtures/files/log_file_100_lines.txt", __dir__)
    @original_ripgrep_enabled = Onlylogs.ripgrep_enabled?
  end

  def teardown
    # Restore original ripgrep setting
    Onlylogs.configuration.ripgrep_enabled = @original_ripgrep_enabled
  end

  # Test with both grep and ripgrep
  [ false, true ].each do |ripgrep_enabled|
    test "it can grep for a simple string in a log file with #{ripgrep_enabled ? 'ripgrep' : 'grep'}" do
      Onlylogs.configuration.ripgrep_enabled = ripgrep_enabled
      lines = Onlylogs::Grep.grep("[DEBUG]", @fixture_path)
      assert_equal 49, lines.length
      assert_equal [ 2, "[DEBUG] Initializing database connection - Line 2" ], lines.first
      assert_equal [ 98, "[DEBUG] Application metrics - Line 98" ], lines.last
    end

    test "it can grep a simple string in a log file and yield each returned line with #{ripgrep_enabled ? 'ripgrep' : 'grep'}" do
      Onlylogs.configuration.ripgrep_enabled = ripgrep_enabled
      lines = []
      Onlylogs::Grep.grep("[DEBUG]", @fixture_path) do |line_number, content|
        lines << [ line_number, content ]
      end
      assert_equal 49, lines.length
      assert_equal [ 2, "[DEBUG] Initializing database connection - Line 2" ], lines.first
      assert_equal [ 98, "[DEBUG] Application metrics - Line 98" ], lines.last
    end

    test "it returns all INFO lines with #{ripgrep_enabled ? 'ripgrep' : 'grep'}" do
      Onlylogs.configuration.ripgrep_enabled = ripgrep_enabled
      lines = Onlylogs::Grep.grep("[INFO]", @fixture_path)
      assert_equal 50, lines.length
      assert_equal [ 1, "[INFO] Application started - Line 1" ], lines.first
      assert_equal [ 99, "[INFO] Metrics collected: 150 data points - Line 99" ], lines.last
    end

    test "it can grep a string when the line contains ansi colors with #{ripgrep_enabled ? 'ripgrep' : 'grep'}" do
      Onlylogs.configuration.ripgrep_enabled = ripgrep_enabled
      # Create a temporary file with ANSI colors for this test
      temp_file = ::File.join(::File.dirname(@fixture_path), "temp_ansi_test.log")
      # Write a line similar to a Rails log line with ANSI colors
      # Example: "\e[1m\e[36mActiveRecord::SchemaMigration Load (0.0ms)\e[0m  \e[1m\e[34mSELECT ...\e[0m"
      line = "\e[1m\e[36mActiveRecord::SchemaMigration Load (0.0ms)\e[0m  \e[1m\e[34mSELECT ...\e[0m"
      ::File.write(temp_file, line)

      lines = Onlylogs::Grep.grep("(0.0ms) SELECT", temp_file)
      assert_equal [ [ 1, line ] ], lines

      # Clean up the temporary file
      ::File.delete(temp_file) if ::File.exist?(temp_file)
    end

    test "it returns empty array when no matches found with #{ripgrep_enabled ? 'ripgrep' : 'grep'}" do
      Onlylogs.configuration.ripgrep_enabled = ripgrep_enabled
      lines = Onlylogs::Grep.grep("NONEXISTENT_PATTERN", @fixture_path)
      assert_equal [], lines
    end
  end




  test "match_line? matches a single line via regular expression" do
    assert Onlylogs::Grep.match_line?("[INFO] Application started - Line 1", "INFO")
    assert Onlylogs::Grep.match_line?("[INFO] Application started - Line 1", "[INFO]")
    assert Onlylogs::Grep.match_line?("[INFO] Application started - Line 1", "[INFO] Application")
    assert Onlylogs::Grep.match_line?("\e[1m\e[36mActiveRecord::SchemaMigration Load (0.0ms)\e[0m  \e[1m\e[34mSELECT ...\e[0m", "(0.0ms) SELECT")
    # assert Onlylogs::Grep.match_line?("[d310974f-969e-4f61-8502-07b7f51fdaef]   [1m[36mCACHE Book Count (0.0ms)[0m  [1m[34mSELECT COUNT(*) FROM \"books\"[0m", "07b7f51fdaef]   CACHE")
  end
end
