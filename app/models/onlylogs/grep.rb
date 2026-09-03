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
    #
    # +on_progress+ is called a few times a second with (bytes_read,
    # bytes_total) for the range being searched. It is the only sign of life a
    # search with no matches gives, so it is what to show a user waiting on
    # one. It runs on a thread of its own, not the caller's. Its return value
    # decides whether the search goes on: +false+ ends it where it is, with the
    # block having seen whatever matched up to there.
    def self.grep(pattern, file_path, start_position: 0, end_position: nil, regexp_mode: false,
      max_matches: Onlylogs.max_line_matches, timeout: nil, on_progress: nil, &block)
      command_args = search_command(pattern, regexp_mode: regexp_mode, max_matches: max_matches)
      start_position, end_position = byte_range(file_path, start_position, end_position)

      results = []
      matches = 0

      ActiveSupport::Notifications.instrument("search.onlylogs", file_path: file_path,
        query: pattern, regexp: regexp_mode, start_position: start_position,
        end_position: end_position, max_matches: max_matches) do |payload|
        each_output_line(command_args, file_path, start_position, end_position,
          timeout: timeout, on_progress: on_progress) do |line|
          offset, content = line.chomp.split(":", 2)
          byte_offset = offset.to_i + start_position

          # The search reads on past the range until it is stopped. What it
          # finds out there is not part of the answer.
          break if byte_offset >= end_position

          # Use String.new to create a copy and prevent memory retention from IO buffers
          content = String.new(content || "", encoding: Encoding::UTF_8).scrub

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

    def self.search_command(pattern, regexp_mode: false, max_matches: Onlylogs.max_line_matches)
      script_name = Onlylogs.ripgrep_enabled? ? "super_ripgrep" : "super_grep"
      super_grep_path = ::File.expand_path("../../../bin/#{script_name}", __dir__)

      command_args = [super_grep_path]
      command_args += ["--max-matches", max_matches.to_s] if max_matches.present?
      command_args << "--regexp" if regexp_mode

      command_args << pattern
    end

    # The slice of the file to search, as [start, end], both clamped into the
    # file so a range past the end is simply empty.
    def self.byte_range(file_path, start_position, end_position)
      file_size = ::File.size(file_path)
      start_position = start_position.clamp(0, file_size)

      [start_position, (end_position || file_size).clamp(start_position, file_size)]
    end

    # Runs the search subprocess and yields its output line by line.
    #
    # The subprocess gets the log file itself as its stdin, opened here and
    # seeked to the start of the range, so it reads the file directly with
    # nothing copying in between. Its reads move the offset of that shared
    # open file description, which is how #watch knows how far it has got.
    #
    # The child is a shell script running rg or grep that can spend minutes
    # scanning a multi-GB file, so two things have to hold. timeout(1) bounds
    # the run and escalates TERM to KILL on the whole pipeline by itself, which
    # covers the deadline. The rest is the caller walking away early - a break
    # out of the yield, an exception, a dropped connection - and there the order
    # below is the point: signal the process group *before* closing the pipe.
    # Closing first waits for a child that, having matched nothing, never wrote
    # and so never received SIGPIPE. That is how a 25 second timeout once turned
    # into a 24 minute request.
    def self.each_output_line(command_args, file_path, start_position, end_position, timeout: nil, on_progress: nil, &block)
      input = ::File.open(file_path, "rb")
      input.seek(start_position)
      reader, writer = IO.pipe

      begin
        pid = Process.spawn(*deprioritised(bounded(command_args, timeout)),
          in: input, out: writer, err: ::File::NULL, pgroup: true)
      rescue
        reader.close
        input.close
        raise
      ensure
        writer.close
      end

      finished = Queue.new
      watcher = Thread.new do
        watch(input, pid, start_position, end_position, on_progress, finished)
      rescue => e
        e
      end

      begin
        reader.each_line(&block)
      ensure
        status = stop(pid)
        finished << true
        watcher.join
        reader.close
        input.close
      end

      raise TimeoutError, "search exceeded #{timeout}s" if status&.exitstatus == TIMED_OUT_EXIT_STATUS
      raise watcher.value if watcher.value.is_a?(Exception)
    end

    POLL_INTERVAL = 0.05 # seconds

    # How far past the end of its range a search may read before it is
    # stopped. The search finishes with one buffer of input before it reads the
    # next, so once it has read this far every line that starts inside the
    # range has been searched and, being line-buffered, written out. No log
    # line comes anywhere near this long.
    END_SLACK = 4 * 1024 * 1024

    # Follows the search through the file from the thread this runs on.
    # Reports where it is to +on_progress+, and stops it when the caller says
    # so or when it has read past the end of its range - left alone, the search
    # would read on to the end of the file. Runs until +finished+ is signalled,
    # then reports one last time so the final position is always seen.
    def self.watch(input, pid, start_position, end_position, on_progress, finished)
      length = end_position - start_position
      report = lambda do |position|
        on_progress.nil? || on_progress.call((position - start_position).clamp(0, length), length) != false
      end

      until finished.pop(timeout: POLL_INTERVAL)
        position = input.sysseek(0, IO::SEEK_CUR)
        return interrupt(pid) unless report.call(position)

        interrupt(pid) if position >= end_position + END_SLACK
      end

      report.call(input.sysseek(0, IO::SEEK_CUR))
    end

    def self.interrupt(pid)
      Process.kill("TERM", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
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
        interrupt(pid)
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

    def self.match_line?(line, string, regexp_mode: false)
      # Strip ANSI color codes from the line before matching
      stripped_line = line.gsub(/\e\[[0-9;]*m/, "")
      # Normalize multiple spaces to single spaces
      normalized_line = stripped_line.gsub(/\s+/, " ")

      pattern = regexp_mode ? string : Regexp.escape(string)
      normalized_line.match?(Regexp.new(pattern, timeout: MATCH_TIMEOUT))
    rescue ::RegexpError
      false
    end
  end
end
