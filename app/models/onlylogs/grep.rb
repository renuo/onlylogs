require "timeout"

module Onlylogs
  class Grep
    # Raised when a search runs past its own +timeout+. It inherits from
    # Timeout::Error so callers that already wrap searches in Timeout.timeout
    # can keep a single rescue.
    class TimeoutError < ::Timeout::Error; end

    # Raised for a pattern Ruby cannot compile, which only matters when +captures+
    # asks Ruby to read its groups back.
    class PatternError < ArgumentError; end

    # +timeout+ is in seconds and defaults to nil, which is no deadline at all:
    # the search runs until it finishes or the caller abandons it. The default
    # is deliberately not a number, because only the caller knows how long it
    # can afford to hold the thread it runs on. Anything serving a request
    # should pass one.
    # +context+ asks for that many lines before and after each match, yielded with
    # <tt>context: true</tt>. It needs ripgrep: plain grep is run without byte
    # offsets, so its context lines could not be told apart from matches, and
    # +context+ is ignored there. Context never reaches outside the byte window.
    # +captures+ treats +pattern+ as a regular expression and yields, under
    # <tt>captures:</tt>, what its groups matched on each match: one entry per group,
    # or the whole match when it has none. The engine finds the line and Ruby reads
    # the groups back from it, so a pattern the two read differently, or one that
    # times out, yields nil there instead.
    def self.grep(pattern, file_path, start_position: 0, end_position: nil, regexp_mode: false,
      case_sensitive: true, max_matches: Onlylogs.max_line_matches, context: 0, captures: false,
      timeout: nil, &block)
      context = 0 unless Onlylogs.ripgrep_enabled?
      regexp_mode ||= captures
      capture_pattern = compile(pattern, case_sensitive: case_sensitive) if captures
      command_args = search_command(pattern, file_path, start_position: start_position,
        end_position: end_position, regexp_mode: regexp_mode, case_sensitive: case_sensitive,
        max_matches: max_matches, context: context)

      results = []

      # ripgrep prints "offset:line" for a match and "offset-line" for context
      parse_line = if Onlylogs.ripgrep_enabled?
        ->(line) {
          offset, separator, content = line.partition(/[:-]/)
          [offset.to_i + start_position, content, separator == "-"]
        }
      else
        ->(line) { [nil, line, false] }
      end

      matches = 0

      ActiveSupport::Notifications.instrument("search.onlylogs", file_path: file_path,
        query: pattern, regexp: regexp_mode, case_sensitive: case_sensitive, start_position: start_position,
        end_position: end_position, max_matches: max_matches) do |payload|
        each_output_line(command_args, timeout: timeout) do |line|
          line = line.chomp
          next if context.positive? && line == GROUP_SEPARATOR

          byte_offset, content, context_line = parse_line.call(line)

          # Use String.new to create a copy and prevent memory retention from IO buffers
          content = String.new(content, encoding: Encoding::UTF_8).scrub

          result = {byte_offset: byte_offset, content: content}
          result[:context] = true if context_line
          result[:captures] = captures_in(capture_pattern, content) if capture_pattern && !context_line
          matches += 1 unless context_line

          if block_given?
            yield result
          else
            results << result
          end
        end
      rescue TimeoutError
        payload[:timed_out] = true
        raise
      ensure
        payload[:matches] = matches
        payload[:timed_out] ||= false
        drop_page_cache(file_path)
      end

      block_given? ? nil : results
    end

    GROUP_SEPARATOR = "--"

    def self.compile(pattern, case_sensitive:)
      Regexp.new(pattern, case_sensitive ? nil : Regexp::IGNORECASE, timeout: MATCH_TIMEOUT)
    rescue ::RegexpError => e
      raise PatternError, "invalid regular expression: #{e.message}"
    end

    def self.captures_in(pattern, content)
      found = pattern.match(content.gsub(ANSI_COLOR, ""))
      return nil unless found

      found.captures.empty? ? [found[0]] : found.captures
    rescue ::Regexp::TimeoutError
      nil
    end

    # The scripts run under LC_ALL=C. ripgrep folds case over Unicode anyway,
    # grep then folds ASCII only: "error" finds "ERROR" with both engines, but
    # "über" finds "Über" with ripgrep only.
    def self.search_command(pattern, file_path, start_position: 0, end_position: nil, regexp_mode: false,
      case_sensitive: true, max_matches: Onlylogs.max_line_matches, context: 0)
      script_name = Onlylogs.ripgrep_enabled? ? "super_ripgrep" : "super_grep"
      super_grep_path = ::File.expand_path("../../../bin/#{script_name}", __dir__)

      command_args = [super_grep_path]
      command_args += ["--max-matches", max_matches.to_s] if max_matches.present?
      command_args += ["--context", context.to_s] if context.positive?
      command_args << "--regexp" if regexp_mode
      command_args << "--case-insensitive" unless case_sensitive

      # Add byte range parameters if specified
      if start_position > 0 || end_position
        command_args << "--start-position" << start_position.to_s
        command_args << "--end-position" << end_position.to_s if end_position
      end

      command_args + [pattern, file_path]
    end

    # Runs the search subprocess and yields its output line by line.
    #
    # The child is a shell pipeline (tail | head | rg) that can spend minutes
    # scanning a multi-GB file, so two things have to hold. timeout(1) bounds
    # the run and escalates TERM to KILL on the whole pipeline by itself, which
    # covers the deadline. The rest is the caller walking away early - a break
    # out of the yield, an exception, a dropped connection - and there the order
    # below is the point: signal the process group *before* closing the pipe.
    # Closing first waits for a child that, having matched nothing, never wrote
    # and so never received SIGPIPE. That is how a 25 second timeout once turned
    # into a 24 minute request.
    def self.each_output_line(command_args, timeout: nil, &block)
      reader, writer = IO.pipe

      begin
        pid = Process.spawn(*deprioritised(bounded(command_args, timeout)),
          out: writer, err: ::File::NULL, pgroup: true)
      rescue
        reader.close
        raise
      ensure
        writer.close
      end

      begin
        reader.each_line(&block)
      ensure
        status = stop(pid)
        reader.close
      end

      raise TimeoutError, "search exceeded #{timeout}s" if status&.exitstatus == TIMED_OUT_EXIT_STATUS
    end

    # timeout(1) exits with this when it had to stop the command.
    TIMED_OUT_EXIT_STATUS = 124
    KILL_GRACE_PERIOD = 0.5

    SEARCH_NICENESS = 19

    def self.deprioritised(command_args)
      ["nice", "-n", SEARCH_NICENESS.to_s, *command_args]
    end

    def self.bounded(command_args, timeout)
      return command_args unless timeout && timeout_command_available?

      ["timeout", "-k", KILL_GRACE_PERIOD.to_s, timeout.to_s, *command_args]
    end

    # Not part of a BSD userland, so a machine without GNU coreutils falls back
    # to whatever deadline the caller imposes. The kill path below still works.
    def self.timeout_command_available?
      return @timeout_command_available if defined?(@timeout_command_available)

      @timeout_command_available = system("command -v timeout > /dev/null 2>&1")
    end

    # Runs while unwinding from an async exception often enough that a second
    # one - another Timeout::Error, a Thread#kill from a shutting down server -
    # could otherwise land between the signal and the reap and leave the
    # pipeline running with nobody left to stop it.
    def self.stop(pid)
      Thread.handle_interrupt(::Exception => :never) do
        begin
          Process.kill("TERM", -pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end

        Process.waitpid2(pid).last
      end
    rescue Errno::ECHILD
      nil
    end

    # Searching a large log file pulls the whole file into the OS page cache.
    # In a container the kernel charges that cache to the cgroup, so a few
    # searches over multi-GB logs can exhaust the memory limit and trigger an
    # OOM kill even though no Ruby memory leaked. Hint the kernel to drop the
    # pages we just read, once the child is gone and nothing is refilling them.
    # Best-effort: advise is only a hint and is unsupported on some platforms,
    # so never let it break a search.
    def self.drop_page_cache(file_path)
      ::File.open(file_path) { |file| file.advise(:dontneed) }
    rescue
      nil
    end

    MATCH_TIMEOUT = 0.1 # seconds
    ANSI_COLOR = /\e\[[0-9;]*m/

    # Folds case over Unicode, like ripgrep. See search_command for grep.
    def self.match_line?(line, string, regexp_mode: false, case_sensitive: true)
      # Strip ANSI color codes from the line before matching
      stripped_line = line.gsub(ANSI_COLOR, "")
      # Normalize multiple spaces to single spaces
      normalized_line = stripped_line.gsub(/\s+/, " ")

      pattern = regexp_mode ? string : Regexp.escape(string)
      options = case_sensitive ? nil : Regexp::IGNORECASE
      normalized_line.match?(Regexp.new(pattern, options, timeout: MATCH_TIMEOUT))
    rescue ::RegexpError
      false
    end
  end
end
