# frozen_string_literal: true

require "test_helper"

module Onlylogs
  class LogsControllerTest < ActionDispatch::IntegrationTest
    setup do
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
      get "/onlylogs/download", params: {log_file_path: @encrypted_path}
      assert_response :success
      assert_equal ::File.read(@log_file), response.body
    end

    test "download returns bad request when log_file_path param is missing" do
      get "/onlylogs/download"
      assert_response :bad_request
    end

    test "download returns bad request when log_file_path param is blank" do
      get "/onlylogs/download", params: {log_file_path: ""}
      assert_response :bad_request
    end

    test "download returns bad request for tampered encrypted token" do
      get "/onlylogs/download", params: {log_file_path: "tampered_garbage"}
      assert_response :bad_request
    end

    test "download returns forbidden for path outside permitted list" do
      encrypted_bad = Onlylogs::SecureFilePath.encrypt("/etc/passwd")
      get "/onlylogs/download", params: {log_file_path: encrypted_bad}
      assert_response :forbidden
    end

    test "download returns not found when file is missing" do
      missing_path = Onlylogs::Engine.root.join("test", "fixtures", "files", "deleted_between_listing_and_download.log").to_s
      assert Onlylogs.file_path_permitted?(missing_path)
      encrypted_missing = Onlylogs::SecureFilePath.encrypt(missing_path)
      get "/onlylogs/download", params: {log_file_path: encrypted_missing}
      assert_response :not_found
    end

    test "index shows download link when log files available" do
      get "/onlylogs"
      assert_response :success
      assert_select "a[href*='download']"
    end

    test "download is basic auth protected when basic auth is enabled" do
      Onlylogs.configure do |config|
        config.disable_basic_authentication = false
        config.basic_auth_user = "user"
        config.basic_auth_password = "password"
      end

      get "/onlylogs/download", params: {log_file_path: @encrypted_path}
      assert_response :unauthorized

      auth_header = {"Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("user", "password")}
      get "/onlylogs/download", params: {log_file_path: @encrypted_path}, headers: auth_header
      assert_response :success
    end

    test "download allows downloading of file with rotation suffix" do
      rotated_log_path = Onlylogs::Engine.root.join("test", "fixtures", "files", "rotated.log.1").to_s
      get "/onlylogs/download", params: {log_file_path: Onlylogs::SecureFilePath.encrypt(rotated_log_path)}
      assert_response :success
    end

    test "download returns forbidden for a file that exists but is not whitelisted" do
      disallowed_path = Onlylogs::Engine.root.join("test", "fixtures", "files", "development.log").to_s

      Onlylogs.configure do |config|
        config.log_file_patterns = [Rails.root.join("log", "*.log")]
      end

      get "/onlylogs/download", params: {log_file_path: Onlylogs::SecureFilePath.encrypt(disallowed_path)}
      assert_response :forbidden

      Onlylogs.configure do |config|
        config.log_file_patterns = [Onlylogs::Engine.root.join("test", "fixtures", "files", "*.log")]
      end

      get "/onlylogs/download", params: {log_file_path: Onlylogs::SecureFilePath.encrypt(disallowed_path)}
      assert_response :success
    end

    test "download returns not found for a file that does not exist but would be whitelisted" do
      not_found_path = Onlylogs::Engine.root.join("test", "fixtures", "files", "nonexistent.log").to_s
      get "/onlylogs/download", params: {log_file_path: Onlylogs::SecureFilePath.encrypt(not_found_path)}
      assert_response :not_found
    end

    test "download returns bad request when encrypted path is not valid" do
      get "/onlylogs/download", params: {log_file_path: "invalid_encrypted_string"}
      assert_response :bad_request
    end

    test "index persists multiple parameters together" do
      get "/onlylogs", params: {filter: "warning", autoscroll: "false", regexp_mode: "true"}
      assert_response :success
      assert_select "[data-log-streamer-filter-value='warning']"
      assert_select "[data-log-streamer-auto-scroll-value='false']"
      assert_select "[data-log-streamer-regexp-mode-value='true']"
    end
  end
end
