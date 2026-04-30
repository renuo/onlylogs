# frozen_string_literal: true

require "test_helper"

module Onlylogs
  class LogsControllerTest < ActionDispatch::IntegrationTest
    setup do
      Onlylogs.instance_variable_set(:@configuration, nil)
      Onlylogs.configure do |config|
        config.disable_basic_authentication = true
        config.log_file_patterns = [
          Onlylogs::Engine.root.join("test", "fixtures", "files", "*.log"),
          Rails.root.join("log", "*.log")
        ]
      end

      @log_file = Onlylogs.available_log_files.first
      @encrypted_path = Onlylogs::SecureFilePath.encrypt(@log_file.to_s)
    end

    test "download sends file for valid encrypted path" do
      get "/onlylogs/download", params: { log_file_path: @encrypted_path }
      assert_response :success
      assert_equal ::File.read(@log_file), response.body
    end

    test "download returns forbidden for invalid encrypted path" do
      get "/onlylogs/download", params: { log_file_path: "tampered_garbage" }
      assert_response :forbidden
    end

    test "download returns forbidden for path outside permitted list" do
      encrypted_bad = Onlylogs::SecureFilePath.encrypt("/etc/passwd")
      get "/onlylogs/download", params: { log_file_path: encrypted_bad }
      assert_response :forbidden
    end

    test "index shows download link when log files available" do
      get "/onlylogs"
      assert_response :success
      assert_select "a[href*='download']"
    end
  end
end
