# frozen_string_literal: true

require "test_helper"

module Onlylogs
  class ConfigurationTest < ActiveSupport::TestCase
    def setup
      # Reset configuration for each test
      Onlylogs.instance_variable_set(:@configuration, nil)

      # Create temporary test files
      @test_dir = Rails.root.join("tmp", "configuration_test")
      FileUtils.mkdir_p(@test_dir)

      @allowed_file = @test_dir.join("allowed.log")
      @disallowed_file = @test_dir.join("disallowed.log")

      ::File.write(@allowed_file, "allowed test content")
      ::File.write(@disallowed_file, "disallowed test content")
    end

    def teardown
      FileUtils.rm_rf(@test_dir) if ::File.exist?(@test_dir)
    end

    test "default configuration includes Rails log file" do
      assert Onlylogs.allowed_file_path?(Rails.root.join("log/#{Rails.env}.log"))
      assert Onlylogs.allowed_file_path?(Rails.root.join("log/#{Rails.env}.log.1"))
      assert Onlylogs.allowed_file_path?(Rails.root.join("log/#{Rails.env}.log.12"))
    end

    test "configure block sets allowed files" do
      Onlylogs.configure do |config|
        config.allowed_files = [ @allowed_file.to_s ]
      end

      assert Onlylogs.allowed_file_path?(@allowed_file.to_s)
      refute Onlylogs.allowed_file_path?(@disallowed_file.to_s)
    end

    test "allowed_file_path? returns true for rotated files" do
      Onlylogs.configure do |config|
        config.allowed_files = [ @allowed_file.to_s ]
      end

      rotated_files = [
        @test_dir.join("allowed.log.0"),
        @test_dir.join("allowed.log.1"),
        @test_dir.join("allowed.log.2"),
        @test_dir.join("allowed.log.999")
      ]

      rotated_files.each do |file|
        ::File.write(file, "rotated content")
      end

      rotated_files.each do |file|
        assert Onlylogs.allowed_file_path?(file.to_s), "#{file} should be allowed"
      end
    end

    test "allowed_file_path? returns false for non-numeric rotated files" do
      Onlylogs.configure do |config|
        config.allowed_files = [ @allowed_file.to_s ]
      end

      non_rotated_files = [
        @test_dir.join("allowed.log.backup"),
        @test_dir.join("allowed.log.old"),
        @test_dir.join("allowed.log.tmp"),
        @test_dir.join("allowed.log.1a"),
        @test_dir.join("allowed.log.a1")
      ]

      non_rotated_files.each do |file|
        ::File.write(file, "non-rotated content")
      end

      non_rotated_files.each do |file|
        refute Onlylogs.allowed_file_path?(file.to_s), "#{file} should not be allowed"
      end
    end

    test "allowed_file_path? handles multiple allowed files" do
      another_allowed = @test_dir.join("another.log")
      ::File.write(another_allowed, "another content")

      Onlylogs.configure do |config|
        config.allowed_files = [ @allowed_file.to_s, another_allowed.to_s ]
      end

      assert Onlylogs.allowed_file_path?(@allowed_file.to_s)
      assert Onlylogs.allowed_file_path?(another_allowed.to_s)

      assert Onlylogs.allowed_file_path?(@test_dir.join("allowed.log.1").to_s)
      assert Onlylogs.allowed_file_path?(@test_dir.join("another.log.1").to_s)

      refute Onlylogs.allowed_file_path?(@disallowed_file.to_s)
    end

    test "allowed_file_path? normalizes file paths" do
      Onlylogs.configure do |config|
        config.allowed_files = [ @allowed_file.to_s ]
      end

      relative_path = Rails.root.join("tmp/configuration_test/allowed.log").to_s
      assert Onlylogs.allowed_file_path?(relative_path)
      assert Onlylogs.allowed_file_path?(Pathname.new(@allowed_file))
    end

    test "allowed_file_path? works with different directories" do
      other_dir = Rails.root.join("tmp", "other_logs")
      FileUtils.mkdir_p(other_dir)

      other_allowed = other_dir.join("other.log")
      ::File.write(other_allowed, "other content")

      Onlylogs.configure do |config|
        config.allowed_files = [ @allowed_file.to_s, other_allowed.to_s ]
      end

      assert Onlylogs.allowed_file_path?(@allowed_file.to_s)
      assert Onlylogs.allowed_file_path?(other_allowed.to_s)

      assert Onlylogs.allowed_file_path?(@test_dir.join("allowed.log.1").to_s)
      assert Onlylogs.allowed_file_path?(other_dir.join("other.log.1").to_s)

      wrong_dir_file = other_dir.join("allowed.log")
      ::File.write(wrong_dir_file, "wrong content")
      refute Onlylogs.allowed_file_path?(wrong_dir_file.to_s)

      FileUtils.rm_rf(other_dir)
    end

    test "allowed_file_path? handles empty configuration" do
      Onlylogs.configure do |config|
        config.allowed_files = []
      end

      refute Onlylogs.allowed_file_path?(@allowed_file.to_s)
      refute Onlylogs.allowed_file_path?(@disallowed_file.to_s)
    end
  end
end
