require "timeout"

module Onlylogs
  class Grep
    # Raised when a search runs past its own +timeout+. It inherits from
    # Timeout::Error so callers that already wrap searches in Timeout.timeout
    # can keep a single rescue.
    class TimeoutError < ::Timeout::Error; end

    # +timeout+ is in seconds and defaults to nil, which is no deadline at all:
    # the search runs until it finishes or the caller abandons it. The default
    # is deliberately not a number, because only the caller knows how long it
    # can afford to hold the thread it runs on. Anything serving a request
    # should pass one.
    def self.grep(pattern, file_path, start_position: 0, end_position: nil, regexp_mode: false,
      max_matches: Onlylogs.max_line_matches, timeout: nil, &block)
      command_args = search_command(pattern, file_path, start_position: start_position,
        end_position: end_position, regexp_mode: regexp_mode, max_matches: max_matches)

      results = []

      # Set up parsing logic based on whether ripgrep includes byte offsets
      parse_line = if Onlylogs.ripgrep_enabled?
        ->(line) {
          parts = line.split(":", 2)
          [parts[0].to_i + start_position, parts[1] || ""]
        }
      else
        ->(line) { [nil, line] }
      end

      matches = 0

      ActiveSupport::Notifications.instrument("search.onlylogs", file_path: file_path,
        query: pattern, regexp: regexp_mode, start_position: start_position,
        end_position: end_position, max_matches: max_matches) do |payload|
        each_output_line(command_args, timeout: timeout) do |line|
          byte_offset, content = parse_line.call(line.chomp)

          # Use String.new to create a copy and prevent memory retention from IO buffers
          content = String.new(content, encoding: Encoding::UTF_8).scrub

          result = {byte_offset: byte_offset, content: content}
          matches += 1

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

    def self.search_command(pattern, file_path, start_position: 0, end_position: nil, regexp_mode: false,
      max_matches: Onlylogs.max_line_matches)
      script_name = Onlylogs.ripgrep_enabled? ? "super_ripgrep" : "super_grep"
      super_grep_path = ::File.expand_path("../../../bin/#{script_name}", __dir__)

      command_args = [super_grep_path]
      command_args += ["--max-matches", max_matches.to_s] if max_matches.present?
      command_args << "--regexp" if regexp_mode

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

    def self.match_line?(line, string, regexp_mode: false)
      # Strip ANSI color codes from the line before matching
      stripped_line = line.gsub(/\e\[[0-9;]*m/, "")
      # Normalize multiple spaces to single spaces
      normalized_line = stripped_line.gsub(/\s+/, " ")

      if regexp_mode
        normalized_line.match?(string)
      else
        normalized_line.match?(Regexp.escape(string))
      end
    end
  end
end
