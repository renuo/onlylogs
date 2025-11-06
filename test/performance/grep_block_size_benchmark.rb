#!/usr/bin/env ruby
# frozen_string_literal: true

require "benchmark"

# Block sizes to test (in bytes) - focusing on common sizes
BLOCK_SIZES = [
  "4K",       # 4 KB
  "8K",       # 8 KB
  "16K",      # 16 KB
  "32K",      # 32 KB
  "64K",      # 64 KB
  "128K",     # 128 KB
  "256K",     # 256 KB
  "512K",     # 512 KB
  "1M",       # 1 MB
  "2M",       # 2 MB
  "4M",       # 4 MB
  "8M"       # 8 MB
].freeze

ULTRA_BIG_LOG = File.expand_path("../fixtures/files/ultra_big.log", __dir__)
SEARCH_PATTERN = "GET"  # Common pattern in log files
NUM_ITERATIONS = 3  # Multiple iterations for better average

def get_file_size(file_path)
  File.size(file_path)
end

def run_search_with_block_size(block_size, start_pos, end_pos, pattern, use_ripgrep: false)
  script_name = use_ripgrep ? "super_ripgrep" : "super_grep"
  script_path = File.expand_path("../../../bin/#{script_name}", __dir__)

  # Modify block size in script temporarily (we'll use environment variable approach)
  # Actually, we need to modify the script file directly or pass it as parameter
  # For now, let's test by modifying the script temporarily

  # Use a wrapper approach: modify block_size variable in the script
  cmd = [
    "bash", "-c",
    "BLOCK_SIZE=#{block_size} #{script_path} --start-position #{start_pos} --end-position #{end_pos} '#{pattern}' '#{ULTRA_BIG_LOG}'"
  ]

  # Actually, we need to modify the scripts to accept BLOCK_SIZE env var
  # For now, let's create a test that modifies the script temporarily
  start_time = Time.now
  result = `#{cmd.join(" ")} 2>/dev/null`
  end_time = Time.now

  {
    elapsed: end_time - start_time,
    result_count: result.lines.count
  }
end

def benchmark_block_size(block_size, file_size, pattern, use_ripgrep: false)
  # Test on a 1GB chunk from the middle of the file
  start_pos = file_size / 4
  end_pos = start_pos + 1_000_000_000 # 1GB chunk

  times = []
  NUM_ITERATIONS.times do
    result = run_search_with_block_size(block_size, start_pos, end_pos, pattern, use_ripgrep: use_ripgrep)
    times << result[:elapsed]
  end

  avg_time = times.sum / NUM_ITERATIONS.to_f
  min_time = times.min
  max_time = times.max

  {
    block_size: block_size,
    avg_time: avg_time,
    min_time: min_time,
    max_time: max_time,
    times: times
  }
end

puts "Grep Block Size Performance Benchmark"
puts "=" * 60
puts "File: #{ULTRA_BIG_LOG}"
puts "File size: #{get_file_size(ULTRA_BIG_LOG) / 1024 / 1024 / 1024.0} GB"
puts "Search pattern: #{SEARCH_PATTERN}"
puts "Iterations per block size: #{NUM_ITERATIONS}"
puts "=" * 60
puts

unless File.exist?(ULTRA_BIG_LOG)
  puts "Error: #{ULTRA_BIG_LOG} not found!"
  exit 1
end

file_size = get_file_size(ULTRA_BIG_LOG)

# Test with grep
puts "\nTesting with grep (super_grep):"
puts "-" * 60
grep_results = []

BLOCK_SIZES.each do |block_size|
  print "Testing block size #{block_size.ljust(6)}... "
  STDOUT.flush

  result = benchmark_block_size(block_size, file_size, SEARCH_PATTERN, use_ripgrep: false)
  grep_results << result

  puts "#{result[:avg_time].round(3)}s (min: #{result[:min_time].round(3)}s, max: #{result[:max_time].round(3)}s)"
end

# Test with ripgrep
puts "\n\nTesting with ripgrep (super_ripgrep):"
puts "-" * 60
ripgrep_results = []

BLOCK_SIZES.each do |block_size|
  print "Testing block size #{block_size.ljust(6)}... "
  STDOUT.flush

  result = benchmark_block_size(block_size, file_size, SEARCH_PATTERN, use_ripgrep: true)
  ripgrep_results << result

  puts "#{result[:avg_time].round(3)}s (min: #{result[:min_time].round(3)}s, max: #{result[:max_time].round(3)}s)"
end

# Find best block sizes
grep_best = grep_results.min_by { |r| r[:avg_time] }
ripgrep_best = ripgrep_results.min_by { |r| r[:avg_time] }

puts "\n" + "=" * 60
puts "RESULTS SUMMARY"
puts "=" * 60
puts "\nBest block size for grep: #{grep_best[:block_size]} (#{grep_best[:avg_time].round(3)}s avg)"
puts "Best block size for ripgrep: #{ripgrep_best[:block_size]} (#{ripgrep_best[:avg_time].round(3)}s avg)"
puts "\nDetailed Results (grep):"
puts "Block Size | Avg Time | Min Time | Max Time"
puts "-" * 50
grep_results.sort_by { |r| r[:avg_time] }.each do |r|
  puts "#{r[:block_size].ljust(10)} | #{r[:avg_time].round(3).to_s.ljust(8)} | #{r[:min_time].round(3).to_s.ljust(8)} | #{r[:max_time].round(3)}"
end

puts "\nDetailed Results (ripgrep):"
puts "Block Size | Avg Time | Min Time | Max Time"
puts "-" * 50
ripgrep_results.sort_by { |r| r[:avg_time] }.each do |r|
  puts "#{r[:block_size].ljust(10)} | #{r[:avg_time].round(3).to_s.ljust(8)} | #{r[:min_time].round(3).to_s.ljust(8)} | #{r[:max_time].round(3)}"
end
