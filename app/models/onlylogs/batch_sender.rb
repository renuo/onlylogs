# frozen_string_literal: true

module Onlylogs
  class BatchSender
    def initialize(channel, interval: 0.05)
      @channel = channel
      @interval = interval
      @buffer = []
      @mutex = Mutex.new
      @running = false
      @sender_thread = nil
    end

    def start
      return if @running

      @running = true
      @sender_thread = Thread.new do
        while @running
          send_batch
          sleep(@interval)
        end
      end
    end

    def stop
      return unless @running

      @running = false
      @sender_thread&.join(0.1)
      
      # Send any remaining lines
      send_batch
    end

    def add_line(line_data)
      @mutex.synchronize do
        @buffer << line_data
      end
    end

    private

    def send_batch
      lines_to_send = nil
      
      @mutex.synchronize do
        return if @buffer.empty?
        lines_to_send = @buffer.dup
        @buffer.clear
      end
      
      return if lines_to_send.empty?

      puts "sending batch of #{lines_to_send.size} lines"
      @channel.send(:transmit, {
        action: "append_logs",
        lines: lines_to_send
      })
    end
  end
end
