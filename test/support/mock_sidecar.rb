# frozen_string_literal: true

require "socket"
require "tmpdir"
require "fileutils"

# A minimal UNIX-socket sidecar to test SocketLogger end-to-end. It binds an ephemeral socket
# in a temp dir and records every line the logger pushes to it, so the delivered lines can be
# asserted (and, crucially, that below-level lines are NOT delivered).
class MockSidecar
  attr_reader :path

  def initialize
    @dir = ::Dir.mktmpdir
    @path = ::File.join(@dir, "onlylogs-sidecar.sock")
    @lines = []
    @mutex = Mutex.new
    @server = UNIXServer.new(@path)
    @thread = Thread.new { accept_loop }
  end

  def received
    @mutex.synchronize { @lines.join("\n") }
  end

  def close
    @server.close
    @thread&.kill
    ::FileUtils.remove_entry(@dir)
  rescue
    nil
  end

  private

  def accept_loop
    conn = @server.accept
    while (line = conn.gets)
      @mutex.synchronize { @lines << line.chomp }
    end
  rescue
    nil
  end
end
