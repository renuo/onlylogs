# frozen_string_literal: true

require "socket"

# A minimal HTTP drain to test HttpLogger end-to-end.
# It binds an ephemeral port, serves keep-alive connections, records every request body it receives, and counts how
# many distinct TCP connections were opened (so connection reuse can be asserted).
# Behaviour is controlled by `status:`:
#   * an Integer (default 200) -> answer every request with that HTTP status
#   * :hang                    -> accept the connection but never reply, so the client blocks
#                                 until its read timeout
class MockDrain
  def initialize(status: 200)
    @status = status
    @bodies = []
    @hanging = []
    @connections = 0
    @mutex = Mutex.new
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { accept_loop }
  end

  def url(path = "/drain")
    "http://127.0.0.1:#{@server.addr[1]}#{path}"
  end

  # Flip the response status at runtime, e.g. to simulate a drain recovering mid-test.
  def status=(value)
    @mutex.synchronize { @status = value }
  end

  def status
    @mutex.synchronize { @status }
  end

  def received
    @mutex.synchronize { @bodies.compact.join("\n") }
  end

  def connection_count
    @mutex.synchronize { @connections }
  end

  def close
    @server.close
    @thread&.join(1)
    @mutex.synchronize { @hanging.each { |conn| close_quietly(conn) } }
  rescue
    nil
  end

  private

  def accept_loop
    loop do
      client = begin
        @server.accept
      rescue
        break
      end
      @mutex.synchronize { @connections += 1 }
      Thread.new(client) { |conn| serve(conn) }
    end
  end

  def serve(conn)
    # Hold the socket open and never reply: the client blocks until its read timeout.
    return @mutex.synchronize { @hanging << conn } if status == :hang

    while handle_request(conn)
    end
    close_quietly(conn)
  end

  # Reads one request and replies; returns true if another may follow on this keep-alive
  # connection, false once the client has closed it.
  def handle_request(conn)
    content_length = 0
    saw_headers = false

    while (line = conn.gets)
      content_length = line.split(": ")[1].to_i if line.start_with?("Content-Length:")
      if line.strip.empty?
        saw_headers = true
        break
      end
    end

    return false unless saw_headers

    body = conn.read(content_length) if content_length > 0
    @mutex.synchronize { @bodies << body } if body

    code = status
    conn.print "HTTP/1.1 #{code} #{Rack::Utils::HTTP_STATUS_CODES.fetch(code, "Status")}\r\nContent-Length: 0\r\n\r\n"
    true
  end

  def close_quietly(conn)
    conn.close
  rescue
    nil
  end
end
