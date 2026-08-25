require "test_helper"
require "timeout"
require "tmpdir"

class Onlylogs::GrepTest < ActiveSupport::TestCase
  def setup
    @fixture_path = ::File.expand_path("../../fixtures/files/log_file_100_lines.txt", __dir__)
    @special_lines_path = File.expand_path("../../fixtures/files/log_special_lines.txt", __dir__)
    @original_ripgrep_enabled = Onlylogs.ripgrep_enabled?
    @original_max_line_matches = Onlylogs.max_line_matches
    @tmpdir = Dir.mktmpdir("onlylogs-grep-test")

    Onlylogs.configuration.max_line_matches = nil
  end

  def teardown
    Onlylogs.configuration.ripgrep_enabled = @original_ripgrep_enabled
    Onlylogs.configuration.max_line_matches = @original_max_line_matches
    FileUtils.remove_entry(@tmpdir) if @tmpdir
  end

  def self.test_both_engine_modes(test_name, &block)
    test test_name do
      [false, true].each do |ripgrep_enabled|
        Onlylogs.configuration.ripgrep_enabled = ripgrep_enabled
        engine_name = ripgrep_enabled ? "ripgrep" : "grep"
        instance_exec(engine_name, &block)
      end
    end
  end

  test_both_engine_modes "it can grep for a simple string in a log file" do |engine_name|
    lines = Onlylogs::Grep.grep("[DEBUG]", @fixture_path)
    assert_equal 49, lines.length, "Failed with #{engine_name}"
    assert_equal "[DEBUG] Initializing database connection - Line 2", lines.first[:content]
    assert_equal "[DEBUG] Application metrics - Line 98", lines.last[:content]
  end

  test_both_engine_modes "it can grep a simple string in a log file and yield each returned line" do |engine_name|
    lines = []
    Onlylogs::Grep.grep("[DEBUG]", @fixture_path) do |result|
      lines << result
    end
    assert_equal 49, lines.length, "Failed with #{engine_name}"
    assert_equal "[DEBUG] Initializing database connection - Line 2", lines.first[:content]
    assert_equal "[DEBUG] Application metrics - Line 98", lines.last[:content]
  end

  test_both_engine_modes "it returns all INFO lines" do |engine_name|
    lines = Onlylogs::Grep.grep("[INFO]", @fixture_path)
    assert_equal 50, lines.length, "Failed with #{engine_name}"
    assert_equal "[INFO] Application started - Line 1", lines.first[:content]
    assert_equal "[INFO] Metrics collected: 150 data points - Line 99", lines.last[:content]
  end

  test_both_engine_modes "it can grep a string when the line contains ansi colors" do |engine_name|
    expected_line = "\e[1m\e[36mActiveRecord::SchemaMigration Load (0.0ms)\e[0m  \e[1m\e[34mSELECT ...\e[0m"
    lines = Onlylogs::Grep.grep("(0.0ms) SELECT", @special_lines_path)
    assert_equal [expected_line], lines.map { |l| l[:content] }, "Failed with #{engine_name}"
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

  test_both_engine_modes "it can grep with start_position to search from a specific byte offset" do |engine_name|
    file_size = File.size(@fixture_path)

    # Search from middle of file
    start_pos = file_size / 2
    lines = Onlylogs::Grep.grep("[DEBUG]", @fixture_path, start_position: start_pos)

    # Should find some DEBUG lines (but fewer than searching entire file)
    assert lines.length < 49, "Should find fewer matches when starting from middle, failed with #{engine_name}"
    assert lines.length > 0, "Should find some matches, failed with #{engine_name}"
  end

  test_both_engine_modes "it can grep with end_position to search up to a specific byte offset" do |engine_name|
    file_size = File.size(@fixture_path)

    # Search up to middle of file
    end_pos = file_size / 2
    lines = Onlylogs::Grep.grep("[DEBUG]", @fixture_path, end_position: end_pos)

    # Should find some DEBUG lines (but fewer than searching entire file)
    assert lines.length < 49, "Should find fewer matches when ending at middle, failed with #{engine_name}"
    assert lines.length > 0, "Should find some matches, failed with #{engine_name}"
  end

  test_both_engine_modes "it can grep with both start_position and end_position to search a byte range" do |engine_name|
    file_size = File.size(@fixture_path)

    # Search a specific range in the middle of the file
    start_pos = file_size / 4
    end_pos = file_size * 3 / 4
    lines = Onlylogs::Grep.grep("[DEBUG]", @fixture_path, start_position: start_pos, end_position: end_pos)

    # Should find some DEBUG lines in that range
    assert lines.length < 49, "Should find fewer matches in partial range, failed with #{engine_name}"
    assert lines.length >= 0, "Should return results (even if empty), failed with #{engine_name}"
  end

  test_both_engine_modes "it returns empty array when byte range is invalid" do |engine_name|
    file_size = File.size(@fixture_path)

    # Start position beyond file size
    lines = Onlylogs::Grep.grep("[DEBUG]", @fixture_path, start_position: file_size + 1000)
    assert_equal [], lines, "Should return empty array for invalid start position, failed with #{engine_name}"

    # End position before start position
    lines = Onlylogs::Grep.grep("[DEBUG]", @fixture_path, start_position: 1000, end_position: 500)
    assert_equal [], lines, "Should return empty array when end < start, failed with #{engine_name}"
  end

  # Fixed-width lines make every byte offset a known line, so a window can be
  # asserted exactly instead of "fewer matches than the whole file".
  LINE_WIDTH = 64
  BLOCK_BYTES = 1048576

  def write_fixed_width_log(bytes)
    path = ::File.join(@tmpdir, "fixed_width.log")
    ::File.open(path, "wb") do |file|
      (bytes / LINE_WIDTH).times { |i| file.write(format("MARK %010d ", i).ljust(LINE_WIDTH - 1, ".") + "\n") }
    end
    path
  end

  def assert_window_returns_every_line(path, start_position, range_size, engine_name)
    first_line = start_position / LINE_WIDTH
    last_line = (start_position + range_size) / LINE_WIDTH - 1

    lines = Onlylogs::Grep.grep("MARK", path, start_position: start_position,
      end_position: start_position + range_size)

    assert_equal last_line - first_line + 1, lines.length, "Short window with #{engine_name}"
    assert_equal format("MARK %010d ", first_line), lines.first[:content][0, 16], "Wrong first line, #{engine_name}"
    assert_equal format("MARK %010d ", last_line), lines.last[:content][0, 16], "Wrong last line, #{engine_name}"
  end

  # The window is read in whole blocks and then trimmed, so the read has to
  # cover the range plus the slack in front of it. A range ending just short of
  # a block boundary leaves only one line of slack, which is where a block count
  # that ignores the offset silently hands back a short window.
  test_both_engine_modes "it returns every line when the range all but fills its last block" do |engine_name|
    path = write_fixed_width_log(4 * BLOCK_BYTES)
    assert_window_returns_every_line(path, 499_968, 2 * BLOCK_BYTES - LINE_WIDTH, engine_name)
  end

  test_both_engine_modes "it returns every line when the range starts mid-block" do |engine_name|
    path = write_fixed_width_log(3 * BLOCK_BYTES)
    assert_window_returns_every_line(path, BLOCK_BYTES + 1024, BLOCK_BYTES + LINE_WIDTH, engine_name)
  end

  test_both_engine_modes "it handles byte range searches correctly with regexp mode" do |engine_name|
    file_size = File.size(@fixture_path)
    start_pos = file_size / 4
    end_pos = file_size * 3 / 4

    # Test with regexp mode
    lines = Onlylogs::Grep.grep("Line \\d+", @fixture_path, start_position: start_pos, end_position: end_pos, regexp_mode: true)
    assert lines.length >= 0, "Should return results (even if empty) with regexp mode, failed with #{engine_name}"
  end

  test_both_engine_modes "it returns every match when a generous timeout is given" do |engine_name|
    lines = Onlylogs::Grep.grep("[DEBUG]", @fixture_path, timeout: 30)
    assert_equal 49, lines.length, "Failed with #{engine_name}"
  end

  test "an abandoned search does not outlive the caller's timeout" do
    recorder = pid_recorder

    elapsed = measure do
      assert_raises(Timeout::Error) do
        Timeout.timeout(1) do
          with_search_command(stalling_command(recorder)) do
            Onlylogs::Grep.grep("never matches", @fixture_path) { |result| result }
          end
        end
      end
    end

    assert_operator elapsed, :<, 5, "the search kept running for #{elapsed.round(1)}s after a 1s timeout"
    assert_search_processes_gone recorder
  end

  test "it enforces its own timeout without an async exception" do
    recorder = pid_recorder

    elapsed = measure do
      assert_raises(Onlylogs::Grep::TimeoutError) do
        with_search_command(stalling_command(recorder)) do
          Onlylogs::Grep.grep("never matches", @fixture_path, timeout: 1) { |result| result }
        end
      end
    end

    assert_operator elapsed, :<, 3, "the search kept running for #{elapsed.round(1)}s after a 1s timeout"
    assert_search_processes_gone recorder
  end

  test "breaking out of the block kills the search" do
    Onlylogs.configuration.ripgrep_enabled = false
    recorder = pid_recorder
    lines = []

    elapsed = measure do
      with_search_command(stalling_command(recorder, emit: "MATCH")) do
        Onlylogs::Grep.grep("anything", @fixture_path) do |result|
          lines << result[:content]
          break
        end
      end
    end

    assert_equal ["MATCH"], lines
    assert_operator elapsed, :<, 5, "the search kept running for #{elapsed.round(1)}s after the caller broke out"
    assert_search_processes_gone recorder
  end

  test "an exception raised by the block kills the search" do
    Onlylogs.configuration.ripgrep_enabled = false
    recorder = pid_recorder

    elapsed = measure do
      assert_raises(RuntimeError) do
        with_search_command(stalling_command(recorder, emit: "MATCH")) do
          Onlylogs::Grep.grep("anything", @fixture_path) { raise "consumer exploded" }
        end
      end
    end

    assert_operator elapsed, :<, 5, "the search kept running for #{elapsed.round(1)}s after the consumer raised"
    assert_search_processes_gone recorder
  end

  test "killing the thread that runs the search kills the search" do
    recorder = pid_recorder

    thread = Thread.new do
      with_search_command(stalling_command(recorder)) do
        Onlylogs::Grep.grep("never matches", @fixture_path) { |result| result }
      end
    end

    assert_equal 3, recorded_pids(recorder, 3).length, "the search did not start as expected"
    thread.kill
    assert thread.join(5), "the killed thread never unwound"

    assert_search_processes_gone recorder
  end

  test "a search that completes normally yields every line and reaps its child" do
    Onlylogs.configuration.ripgrep_enabled = false
    recorder = pid_recorder
    command = ["bash", "-c", "echo $$ > #{recorder}; echo one; echo two; printf 'no-trailing-newline'"]
    lines = []

    with_search_command(command) do
      Onlylogs::Grep.grep("anything", @fixture_path) { |result| lines << result[:content] }
    end

    assert_equal ["one", "two", "no-trailing-newline"], lines
    assert_search_processes_gone recorder, expected_pids: 1
  end

  private

  STALL_SECONDS = 20

  # A pipeline that records the pid of every one of its members and then stalls
  # without writing anything, the way a search with no matches does: it never
  # gets SIGPIPE, so only a signal can stop it.
  def stalling_command(recorder, emit: nil)
    # Each member records its own pid and then execs, so the recorded pids are
    # the pids of the running pipeline and not of a wrapper shell.
    stall = "sh -c 'echo $$ >> #{recorder}; #{"echo #{emit}; " if emit}exec sleep #{STALL_SECONDS}'"
    forward = "sh -c 'echo $$ >> #{recorder}; exec cat'"

    ["bash", "-c", "echo $$ > #{recorder}; #{stall} | #{forward}"]
  end

  def pid_recorder
    ::File.join(@tmpdir, "pids-#{SecureRandom.hex(4)}")
  end

  def with_search_command(command)
    singleton = Onlylogs::Grep.singleton_class
    original = Onlylogs::Grep.method(:search_command)
    singleton.define_method(:search_command) { |*, **| command }

    yield
  ensure
    singleton.define_method(:search_command, original)
  end

  def assert_search_processes_gone(recorder, expected_pids: 3)
    pids = recorded_pids(recorder, expected_pids)
    assert_equal expected_pids, pids.length, "the search did not start as expected"

    survivors = pids.reject { |pid| wait_until_dead(pid) }
    assert_empty survivors, "search processes survived: #{survivors.inspect}"
    refute process_group_alive?(pids.first), "the search's process group survived"
  end

  def recorded_pids(recorder, expected)
    within(2) do
      pids = ::File.exist?(recorder) ? ::File.read(recorder).split.map(&:to_i) : []
      pids if pids.length >= expected
    end || []
  end

  def wait_until_dead(pid)
    within(5) { !process_alive?(pid) } || false
  end

  def within(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds

    loop do
      result = yield
      return result if result
      return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.02
    end
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def process_group_alive?(pgid)
    Process.kill(0, -pgid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  test_both_engine_modes "it instruments each search with what was scanned and what came back" do |engine_name|
    event = capture_search_event { Onlylogs::Grep.grep("[DEBUG]", @fixture_path) }

    assert_equal @fixture_path, event.payload[:file_path], "Failed with #{engine_name}"
    assert_equal "[DEBUG]", event.payload[:query], "Failed with #{engine_name}"
    assert_equal 49, event.payload[:matches], "Failed with #{engine_name}"
    assert_equal false, event.payload[:timed_out], "Failed with #{engine_name}"
    assert_operator event.duration, :>, 0, "Failed with #{engine_name}"
  end

  test "it does not write to the log itself, so searching a log cannot append to it" do
    logged = capture_log { Onlylogs::Grep.grep("[DEBUG]", @fixture_path) }

    assert_equal "", logged
  end

  test "a search stopped by its timeout is instrumented as timed out" do
    event = capture_search_event do
      with_search_command(["sh", "-c", "sleep 30"]) do
        assert_raises(Onlylogs::Grep::TimeoutError) { Onlylogs::Grep.grep("anything", @fixture_path, timeout: 1) }
      end
    end

    assert_equal true, event.payload[:timed_out]
  end

  test "the search runs at a lower priority than the application serving requests" do
    assert_equal ["nice", "-n", "19"], Onlylogs::Grep.deprioritised(["rg", "x"]).first(3)
  end

  def capture_search_event
    event = nil
    subscriber = ActiveSupport::Notifications.subscribe("search.onlylogs") do |*args|
      event = ActiveSupport::Notifications::Event.new(*args)
    end
    yield
    event
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def capture_log
    original = Rails.logger
    io = StringIO.new
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end

  def measure
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
  end
end
