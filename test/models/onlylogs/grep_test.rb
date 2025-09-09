require "test_helper"

class Onlylogs::GrepTest < ActiveSupport::TestCase
  def setup
    @fixture_path = ::File.expand_path("../../fixtures/files/log_file_100_lines.txt", __dir__)
  end

  test "it can grep for a simple string in a log file" do
    lines = Onlylogs::Grep.grep("[DEBUG]", @fixture_path)
    assert_equal 49, lines.length
    assert_equal [ 2, "[DEBUG] Initializing database connection - Line 2" ], lines.first
    assert_equal [ 98, "[DEBUG] Application metrics - Line 98" ], lines.last
  end

  test "it can grep a simple string in a log file and yield each returned line" do
    lines = []
    Onlylogs::Grep.grep("[DEBUG]", @fixture_path) do |line_number, content|
      lines << [ line_number, content ]
    end
    assert_equal 49, lines.length
    assert_equal [ 2, "[DEBUG] Initializing database connection - Line 2" ], lines.first
    assert_equal [ 98, "[DEBUG] Application metrics - Line 98" ], lines.last
  end



  test "it returns all INFO lines" do
    lines = Onlylogs::Grep.grep("[INFO]", @fixture_path)
    assert_equal 50, lines.length
    assert_equal [ 1, "[INFO] Application started - Line 1" ], lines.first
    assert_equal [ 99, "[INFO] Metrics collected: 150 data points - Line 99" ], lines.last
  end


  # test "it can grep on the first 25% of the file" do
  #  lines = Onlylogs::Grep.grep("[DEBUG]", @fixture_path, start_position: 0, end_position: 25)
  #  assert_equal 12, lines.length
  # end

  test "it can grep a string when the line contains ansi colors" do
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


  test "it returns empty array when no matches found" do
    lines = Onlylogs::Grep.grep("NONEXISTENT_PATTERN", @fixture_path)
    assert_equal [], lines
  end



  test "match_line? matches a single line via regular expression" do
    assert Onlylogs::Grep.match_line?("[INFO] Application started - Line 1", "INFO")
    assert Onlylogs::Grep.match_line?("[INFO] Application started - Line 1", "[INFO]")
    assert Onlylogs::Grep.match_line?("[INFO] Application started - Line 1", "[INFO] Application")
    assert Onlylogs::Grep.match_line?("\e[1m\e[36mActiveRecord::SchemaMigration Load (0.0ms)\e[0m  \e[1m\e[34mSELECT ...\e[0m", "(0.0ms) SELECT")
    # assert Onlylogs::Grep.match_line?("[d310974f-969e-4f61-8502-07b7f51fdaef]   [1m[36mCACHE Book Count (0.0ms)[0m  [1m[34mSELECT COUNT(*) FROM \"books\"[0m", "07b7f51fdaef]   CACHE")
  end

  test "it does not allocate memory for results when using a block" do
    # Use the same large test file for fair comparison
    large_fixture_path = ::File.expand_path("../../fixtures/files/big.log", __dir__)

    # Force garbage collection to get a clean baseline
    GC.start
    GC.compact if GC.respond_to?(:compact)

    # Get initial memory usage
    initial_memory = `ps -o rss= -p #{Process.pid}`.to_i

    # Track memory usage during processing
    max_memory_during_processing = initial_memory
    line_count = 0

    10.times do
      Onlylogs::Grep.grep("heroku router", large_fixture_path) do |line_number, content|
        line_count += 1

        # Check memory usage every 100,000 lines to catch peak usage
        if line_count % 100000 == 0
          current_memory = `ps -o rss= -p #{Process.pid}`.to_i
          max_memory_during_processing = [ max_memory_during_processing, current_memory ].max
        end

        # Process the line but don't store it
        content.length
      end
    end

    GC.start
    GC.compact if GC.respond_to?(:compact)

    # Get final memory usage after processing
    final_memory = `ps -o rss= -p #{Process.pid}`.to_i
    peak_memory_increase = max_memory_during_processing - initial_memory
    final_memory_increase = final_memory - initial_memory

    # We should have processed many lines
    assert line_count > 1000000, "Expected to process many lines, got #{line_count}"

    # Peak memory during processing should be much less than collecting all results
    # Even with streaming, some memory is used for string processing and regex matching
    assert peak_memory_increase < 200000, "Peak memory increase during processing was #{peak_memory_increase}KB, expected reasonable memory usage for #{line_count} lines"

    # Final memory should be much less than collecting all results
    # Some memory remains due to Ruby's internal string handling and GC behavior
    assert final_memory_increase < 50000, "Final memory increase was #{final_memory_increase}KB, expected much less than collecting all results"

    puts "Processed #{line_count} lines - Initial memory: #{initial_memory / 1024}MB, Final memory: #{final_memory / 1024}MB, Max memory: #{max_memory_during_processing / 1024}MB"
  end

  test "it allocates memory for results when not using a block" do
    # Use a larger test file to make memory differences more visible
    large_fixture_path = ::File.expand_path("../../fixtures/files/big.log", __dir__)

    # Force garbage collection to get a clean baseline
    GC.start
    GC.compact if GC.respond_to?(:compact)

    # Get initial memory usage
    initial_memory = `ps -o rss= -p #{Process.pid}`.to_i

    # Get all results as an array (this should allocate memory)
    # Use a pattern that returns many results
    results = Onlylogs::Grep.grep("heroku router", large_fixture_path)

    # Get memory usage after processing
    final_memory = `ps -o rss= -p #{Process.pid}`.to_i
    memory_increase = final_memory - initial_memory

    # We should have results and memory should be allocated to store them
    assert results.length > 1000000, "Expected to find many results, got #{results.length}"
    assert memory_increase > 10000, "Memory increase was #{memory_increase}KB, expected significant memory allocation for #{results.length} results"

    puts "Collected #{results.length} results - Initial memory: #{initial_memory / 1024}MB, Final memory: #{final_memory / 1024}MB, Memory increase: #{memory_increase / 1024}MB"

    # Keep a reference to results to prevent garbage collection during the test
    results.length
  end
end
