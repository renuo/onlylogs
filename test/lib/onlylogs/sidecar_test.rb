require "test_helper"
require "socket"
require "tmpdir"
require "timeout"

# Runs bin/onlylogs_sidecar against a fake drain on localhost.
class Onlylogs::SidecarTest < ActiveSupport::TestCase
  SIDECAR = File.expand_path("../../../bin/onlylogs_sidecar", __dir__)

  setup do
    @dir = Dir.mktmpdir("onlylogs-sidecar-test")
    @socket_path = File.join(@dir, "sidecar.sock")
    @drain = TCPServer.new("127.0.0.1", 0)
    @bodies = Queue.new
    @drain_thread = Thread.new { serve_drain }
  end

  teardown do
    stop_sidecar
    @drain_thread.kill
    @drain.close
    FileUtils.remove_entry(@dir)
  end

  # The app's logger already writes every line to stdout, which the sidecar shares with Puma:
  # printing the batch again would double the app's log output.
  test "sends lines to the drain without printing them to stdout" do
    stdout = File.join(@dir, "stdout")
    @pid = Process.spawn({"ONLYLOGS_DRAIN_URL" => "http://127.0.0.1:#{@drain.addr[1]}/drain/code",
                          "ONLYLOGS_SIDECAR_SOCKET" => @socket_path, "ONLYLOGS_FLUSH_INTERVAL" => "0.1"},
      RbConfig.ruby, SIDECAR, out: stdout, err: File::NULL)

    Timeout.timeout(10) { sleep 0.05 until File.exist?(@socket_path) }
    UNIXSocket.open(@socket_path) { |socket| socket.puts "hello drain" }

    assert_equal "hello drain", Timeout.timeout(10) { @bodies.pop }
    stop_sidecar # its stdout is buffered until it exits
    refute_includes File.read(stdout), "hello drain"
  end

  private

  def stop_sidecar
    return unless @pid
    Process.kill("TERM", @pid)
    Process.wait(@pid)
    @pid = nil
  end

  def serve_drain
    loop do
      client = @drain.accept
      length = 0
      while (line = client.gets) && line != "\r\n"
        length = line.split(":", 2).last.to_i if line.downcase.start_with?("content-length:")
      end
      @bodies << client.read(length)
      client.write "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nok\n"
      client.close
    end
  end
end
