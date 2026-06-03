#!/usr/bin/env ruby
# Continuous log writer - appends logs for testing
# Usage: ruby continuous_log_writer.rb [logs_per_batch] [interval_seconds]
# Example: ruby continuous_log_writer.rb 5 1  (5 logs every 1 second)

log_file = File.expand_path("log/development.log", __dir__)
logs_per_batch = (ARGV[0] || 1).to_i
interval = (ARGV[1] || 2).to_i
counter = 0

puts "📝 Writing #{logs_per_batch} log(s) to #{log_file} every #{interval} second(s)..."
puts "Press Ctrl+C to stop"
puts

loop do
  logs_per_batch.times do
    counter += 1
    timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S.%3N")

    log_messages = [
      "I, [#{timestamp} ##{Process.pid}]  INFO -- : Processing request #{counter}",
      "D, [#{timestamp} ##{Process.pid}] DEBUG -- : User action detected - #{["click", "scroll", "select", "hover"].sample}",
      "W, [#{timestamp} ##{Process.pid}]  WARN -- : Slow query detected - #{rand(100..5000)}ms",
      "I, [#{timestamp} ##{Process.pid}]  INFO -- : Request completed with status 200",
      "I, [#{timestamp} ##{Process.pid}]  INFO -- : [#{counter}] Started GET \"/onlylogs\" for 127.0.0.1"
    ].sample

    File.open(log_file, "a") do |f|
      f.puts log_messages
    end

    puts "✓ Added log #{counter}: #{log_messages[0..60]}..."
  end

  sleep interval
end
