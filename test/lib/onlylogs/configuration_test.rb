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

    test "configure block sets allowed files" do
      Onlylogs.configure do |config|
        config.allowed_files = [ @allowed_file.to_s ]
      end

      assert Onlylogs.allowed_file_path?(@allowed_file.to_s)
      refute Onlylogs.allowed_file_path?(@disallowed_file.to_s)
    end


    test "allowed_file_path? handles multiple allowed files" do
      another_allowed = @test_dir.join("another.log")
      ::File.write(another_allowed, "another content")

      Onlylogs.configure do |config|
        config.allowed_files = [ @allowed_file.to_s, another_allowed.to_s ]
      end

      assert Onlylogs.allowed_file_path?(@allowed_file.to_s)
      assert Onlylogs.allowed_file_path?(another_allowed.to_s)

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

    test "allowed_file_path? supports glob patterns" do
      # Create various log files
      log_files = [
        @test_dir.join("app.log"),
        @test_dir.join("api.log"),
        @test_dir.join("debug.log"),
        @test_dir.join("error.log")
      ]

      # Create non-log files
      non_log_files = [
        @test_dir.join("app.log.1"),
        @test_dir.join("config.txt"),
        @test_dir.join("data.json"),
        @test_dir.join("script.rb")
      ]

      # Create all files
      (log_files + non_log_files).each do |file|
        ::File.write(file, "content")
      end

      Onlylogs.configure do |config|
        config.allowed_files = [ @test_dir.join("*.log").to_s ]
      end

      # All .log files should be allowed
      log_files.each do |file|
        assert Onlylogs.allowed_file_path?(file.to_s), "#{file} should be allowed by *.log pattern"
      end

      # Non-log files should not be allowed
      non_log_files.each do |file|
        refute Onlylogs.allowed_file_path?(file.to_s), "#{file} should not be allowed by *.log pattern"
      end
    end

    test "default authentication credentials are nil" do
      assert_nil Onlylogs.http_basic_auth_user
      assert_nil Onlylogs.http_basic_auth_password
    end

    test "basic auth is not configured by default" do
      assert_not Onlylogs.basic_auth_configured?
    end

    test "authentication credentials can be configured" do
      Onlylogs.configure do |config|
        config.http_basic_auth_user = "admin"
        config.http_basic_auth_password = "secure_password"
      end

      assert_equal "admin", Onlylogs.http_basic_auth_user
      assert_equal "secure_password", Onlylogs.http_basic_auth_password
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
