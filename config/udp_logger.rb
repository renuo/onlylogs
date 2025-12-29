# udp_logger.rb
require "logger"
require "socket"

class UdpLogger < Logger
  def initialize(host: "127.0.0.1", port: 6000, local_fallback: $stdout)
    # Use a normal Logger underneath so we still see logs locally
    super(local_fallback)

    @udp_host = host
    @udp_port = port
    @socket   = UDPSocket.new
  end

  # Override Logger#add, which all the level methods delegate to
  def add(severity, message = nil, progname = nil, &block)
    # Same semantics as Logger:
    if message.nil?
      if block_given?
        message = block.call
      else
        message = progname
        progname = nil
      end
    end

    # Send plain text over UDP to Vector
    begin
      payload = message.to_s
      @socket.send(payload, 0, @udp_host, @udp_port)
    rescue => e
      # Swallow UDP errors so logging never crashes the app
      warn "UDP logger error: #{e.class}: #{e.message}"
    end

    # Also log locally (stdout / file) via normal Logger behavior
    super(severity, message, progname, &block)
  end
end

