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
      assert Onlylogs.file_path_permitted?(Rails.root.join("log/#{Rails.env}.log"))
    end

    test "default_log_file_path returns Rails log file path" do
      expected_path = Rails.root.join("log/#{Rails.env}.log").to_s
      assert_equal expected_path, Onlylogs.default_log_file_path
    end

    test "default_log_file_path can be configured" do
      custom_path = @test_dir.join("custom.log").to_s

      Onlylogs.configure do |config|
        config.default_log_file_path = custom_path
      end

      assert_equal custom_path, Onlylogs.default_log_file_path
    end

    test "configure block sets log file patterns" do
      Onlylogs.configure do |config|
        config.log_file_patterns = [ @allowed_file.to_s ]
      end

      assert Onlylogs.file_path_permitted?(@allowed_file.to_s)
      refute Onlylogs.file_path_permitted?(@disallowed_file.to_s)
    end


    test "file_path_permitted? handles multiple allowed files" do
      another_allowed = @test_dir.join("another.log")
      ::File.write(another_allowed, "another content")

      Onlylogs.configure do |config|
        config.log_file_patterns = [ @allowed_file.to_s, another_allowed.to_s ]
      end

      assert Onlylogs.file_path_permitted?(@allowed_file.to_s)
      assert Onlylogs.file_path_permitted?(another_allowed.to_s)

      refute Onlylogs.file_path_permitted?(@disallowed_file.to_s)
    end

    test "file_path_permitted? normalizes file paths" do
      Onlylogs.configure do |config|
        config.log_file_patterns = [ @allowed_file.to_s ]
      end

      relative_path = Rails.root.join("tmp/configuration_test/allowed.log").to_s
      assert Onlylogs.file_path_permitted?(relative_path)
      assert Onlylogs.file_path_permitted?(Pathname.new(@allowed_file))
    end

    test "file_path_permitted? works with different directories" do
      other_dir = Rails.root.join("tmp", "other_logs")
      FileUtils.mkdir_p(other_dir)

      other_allowed = other_dir.join("other.log")
      ::File.write(other_allowed, "other content")

      Onlylogs.configure do |config|
        config.log_file_patterns = [ @allowed_file.to_s, other_allowed.to_s ]
      end

      assert Onlylogs.file_path_permitted?(@allowed_file.to_s)
      assert Onlylogs.file_path_permitted?(other_allowed.to_s)

      wrong_dir_file = other_dir.join("allowed.log")
      ::File.write(wrong_dir_file, "wrong content")
      refute Onlylogs.file_path_permitted?(wrong_dir_file.to_s)

      FileUtils.rm_rf(other_dir)
    end

    test "file_path_permitted? handles empty configuration" do
      Onlylogs.configure do |config|
        config.log_file_patterns = []
      end

      refute Onlylogs.file_path_permitted?(@allowed_file.to_s)
      refute Onlylogs.file_path_permitted?(@disallowed_file.to_s)
    end

    test "file_path_permitted? supports glob patterns including rotated log files" do
      # Create various log files
      log_files = [
        @test_dir.join("app.log"),
        @test_dir.join("api.log"),
        @test_dir.join("debug.log"),
        @test_dir.join("error.log")
      ]

      # Create non-log files
      rotated_log_files = [
        @test_dir.join("app.log.1")
      ]

      non_log_files = [
        @test_dir.join("config.txt"),
        @test_dir.join("data.json"),
        @test_dir.join("script.rb")
      ]

      # Create all files
      (log_files + rotated_log_files + non_log_files).each do |file|
        ::File.write(file, "content")
      end

      Onlylogs.configure do |config|
        config.log_file_patterns = [ @test_dir.join("*.log").to_s ]
      end

      # All .log files should be allowed
      log_files.each do |file|
        assert Onlylogs.file_path_permitted?(file.to_s), "#{file} should be allowed by *.log pattern"
      end

      rotated_log_files.each do |file|
        assert Onlylogs.file_path_permitted?(file.to_s), "#{file} should be allowed by *.log pattern"
      end

      # Non-log files should not be allowed
      non_log_files.each do |file|
        refute Onlylogs.file_path_permitted?(file.to_s), "#{file} should not be allowed by *.log pattern"
      end
    end

    test "file_path_permitted? allows rotated files for .log glob patterns" do
      base_log_file = @test_dir.join("development.log")
      rotated_log_file = @test_dir.join("development.log.1")
      compressed_rotated_log_file = @test_dir.join("development.log.2.gz")
      non_log_file = @test_dir.join("development.txt")

      ::File.write(base_log_file, "base content")
      ::File.write(rotated_log_file, "rotated content")
      ::File.write(compressed_rotated_log_file, "compressed rotated content")
      ::File.write(non_log_file, "non log content")

      Onlylogs.configure do |config|
        config.log_file_patterns = [ @test_dir.join("*.log").to_s ]
      end

      assert Onlylogs.file_path_permitted?(base_log_file.to_s)
      assert Onlylogs.file_path_permitted?(rotated_log_file.to_s)
      assert Onlylogs.file_path_permitted?(compressed_rotated_log_file.to_s)
      refute Onlylogs.file_path_permitted?(non_log_file.to_s)
    end

    test "file_path_permitted? allows rotated files for explicitly allowed log files" do
      rotated_log_file = @test_dir.join("allowed.log.1")
      compressed_rotated_log_file = @test_dir.join("allowed.log.2.gz")
      unrelated_file = @test_dir.join("allowed.logfile")

      ::File.write(rotated_log_file, "rotated content")
      ::File.write(compressed_rotated_log_file, "compressed rotated content")
      ::File.write(unrelated_file, "unrelated content")

      Onlylogs.configure do |config|
        config.log_file_patterns = [ @allowed_file.to_s ]
      end

      assert Onlylogs.file_path_permitted?(rotated_log_file.to_s)
      assert Onlylogs.file_path_permitted?(compressed_rotated_log_file.to_s)
      refute Onlylogs.file_path_permitted?(unrelated_file.to_s)
    end

    test "available_log_files includes rotated files for explicitly allowed log files" do
      rotated_log_file = @test_dir.join("allowed.log.1")
      compressed_rotated_log_file = @test_dir.join("allowed.log.2.gz")
      missing_rotated_log_file = @test_dir.join("allowed.log.3")

      ::File.write(rotated_log_file, "rotated content")
      ::File.write(compressed_rotated_log_file, "compressed rotated content")

      Onlylogs.configure do |config|
        config.log_file_patterns = [ @allowed_file.to_s ]
      end

      assert_equal [
        @allowed_file,
        rotated_log_file,
        compressed_rotated_log_file
      ].sort, Onlylogs.available_log_files.sort
      refute_includes Onlylogs.available_log_files, missing_rotated_log_file
    end

    test "available_log_files includes rotated files for .log glob patterns" do
      base_log_file = @test_dir.join("development.log")
      rotated_log_file = @test_dir.join("development.log.1")
      compressed_rotated_log_file = @test_dir.join("development.log.2.gz")
      non_log_file = @test_dir.join("development.txt")

      ::File.write(base_log_file, "base content")
      ::File.write(rotated_log_file, "rotated content")
      ::File.write(compressed_rotated_log_file, "compressed rotated content")
      ::File.write(non_log_file, "non log content")

      Onlylogs.configure do |config|
        config.log_file_patterns = [ @test_dir.join("*.log").to_s ]
      end

      assert_equal [
        @allowed_file,
        @disallowed_file,
        base_log_file,
        rotated_log_file,
        compressed_rotated_log_file
      ].sort, Onlylogs.available_log_files.sort
      refute_includes Onlylogs.available_log_files, non_log_file
    end

    test "default authentication credentials are nil" do
      assert_nil Onlylogs.basic_auth_user
      assert_nil Onlylogs.basic_auth_password
    end

    test "basic auth is not configured by default" do
      assert_not Onlylogs.basic_auth_configured?
    end

    test "authentication credentials can be configured" do
      Onlylogs.configure do |config|
        config.basic_auth_user = "admin"
        config.basic_auth_password = "secure_password"
      end

      assert_equal "admin", Onlylogs.basic_auth_user
      assert_equal "secure_password", Onlylogs.basic_auth_password
      assert Onlylogs.basic_auth_configured?
    end

    test "parent_controller can be configured" do
      Onlylogs.configure do |config|
        config.parent_controller = "AdminController"
      end

      assert_equal "AdminController", Onlylogs.parent_controller
    end

    test "disable_basic_authentication can be configured" do
      assert_equal false, Onlylogs.disable_basic_authentication?

      Onlylogs.configure do |config|
        config.disable_basic_authentication = true
      end

      assert_equal true, Onlylogs.disable_basic_authentication?
    end
  end
end
