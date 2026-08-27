# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

module Onlylogs
  class QueriesControllerTest < ActionDispatch::IntegrationTest
    # Each test works against a throwaway SQLite database in a temp directory
    # that teardown deletes. Transactional fixtures would reconnect to those
    # pools afterwards to roll back, by which point the files are gone.
    self.use_transactional_tests = false

    setup do
      # Saved queries land in a SQLite database next to the log file, so tests
      # run against a throwaway directory rather than the fixture files.
      @temp_dir = Dir.mktmpdir
      @log_file_path = ::File.join(@temp_dir, "test.log")
      ::File.write(@log_file_path, "test log content\n")

      # Configuration is global, so remember what to put back.
      @original_config = Onlylogs.configuration.then do |current|
        {
          log_file_patterns: current.log_file_patterns,
          disable_basic_authentication: current.disable_basic_authentication,
          basic_auth_user: current.basic_auth_user,
          basic_auth_password: current.basic_auth_password
        }
      end

      Onlylogs.configure do |config|
        config.disable_basic_authentication = true
        config.log_file_patterns = [::File.join(@temp_dir, "*.log")]
      end

      QueryDatabase.clear_connections

      @encrypted_path = SecureFilePath.encrypt(@log_file_path)
    end

    teardown do
      QueryDatabase.clear_connections
      FileUtils.remove_entry(@temp_dir) if ::File.directory?(@temp_dir)

      Onlylogs.configure do |config|
        @original_config.each { |name, value| config.public_send(:"#{name}=", value) }
      end
    end

    # index

    test "index returns an empty list when nothing is saved" do
      get "/onlylogs/queries", params: {log_file_path: @encrypted_path}

      assert_response :success
      assert_equal [], response.parsed_body["queries"]
    end

    test "index returns the saved queries most recently updated first" do
      create_query(name: "Older", filter: "ERROR")
      create_query(name: "Newer", filter: "WARN")

      get "/onlylogs/queries", params: {log_file_path: @encrypted_path}

      assert_response :success
      assert_equal ["Newer", "Older"], response.parsed_body["queries"].map { |q| q["name"] }
    end

    # create

    test "create saves a query and returns it" do
      post "/onlylogs/queries",
        params: {log_file_path: @encrypted_path, name: "Errors", filter: "ERROR", regexp_mode: true},
        as: :json

      assert_response :created
      assert_equal "Errors", response.parsed_body["name"]
      assert_equal "ERROR", response.parsed_body["filter"]
      assert_equal true, response.parsed_body["regexp_mode"]
    end

    test "create ignores attributes that are not permitted" do
      post "/onlylogs/queries",
        params: {log_file_path: @encrypted_path, name: "Errors", filter: "ERROR", id: 999},
        as: :json

      assert_response :created
      assert_not_equal 999, response.parsed_body["id"]
    end

    test "create returns unprocessable entity for a blank name" do
      post "/onlylogs/queries",
        params: {log_file_path: @encrypted_path, name: "", filter: "ERROR"},
        as: :json

      assert_response :unprocessable_entity
      assert_includes response.parsed_body["errors"]["name"], "can't be blank"
      assert_predicate response.parsed_body["error"], :present?
    end

    test "create returns unprocessable entity for a duplicate name" do
      create_query(name: "Errors", filter: "ERROR")

      post "/onlylogs/queries",
        params: {log_file_path: @encrypted_path, name: "errors", filter: "WARN"},
        as: :json

      assert_response :unprocessable_entity
      assert_includes response.parsed_body["errors"]["name"], "has already been taken"
    end

    test "create returns unprocessable entity for an invalid regexp" do
      post "/onlylogs/queries",
        params: {log_file_path: @encrypted_path, name: "Broken", filter: "[invalid", regexp_mode: true},
        as: :json

      assert_response :unprocessable_entity
      assert_predicate response.parsed_body["errors"]["filter"], :any?
    end

    # show

    test "show returns the query" do
      query = create_query(name: "Errors", filter: "ERROR")

      get "/onlylogs/queries/#{query["id"]}", params: {log_file_path: @encrypted_path}

      assert_response :success
      assert_equal "Errors", response.parsed_body["name"]
    end

    test "show returns not found for an unknown id" do
      get "/onlylogs/queries/123456", params: {log_file_path: @encrypted_path}

      assert_response :not_found
      assert_predicate response.parsed_body["error"], :present?
    end

    # update

    test "update changes the query" do
      query = create_query(name: "Before", filter: "ERROR")

      patch "/onlylogs/queries/#{query["id"]}",
        params: {log_file_path: @encrypted_path, name: "After", filter: "WARN", regexp_mode: true},
        as: :json

      assert_response :success
      assert_equal "After", response.parsed_body["name"]
      assert_equal "WARN", response.parsed_body["filter"]
      assert_equal true, response.parsed_body["regexp_mode"]
    end

    test "update returns unprocessable entity for a duplicate name" do
      create_query(name: "Taken", filter: "ERROR")
      query = create_query(name: "Mine", filter: "WARN")

      patch "/onlylogs/queries/#{query["id"]}",
        params: {log_file_path: @encrypted_path, name: "Taken"},
        as: :json

      assert_response :unprocessable_entity
      assert_includes response.parsed_body["errors"]["name"], "has already been taken"
    end

    test "update returns not found for an unknown id" do
      patch "/onlylogs/queries/123456",
        params: {log_file_path: @encrypted_path, name: "Nope"},
        as: :json

      assert_response :not_found
    end

    # destroy

    test "destroy removes the query" do
      query = create_query(name: "Temporary", filter: "DEBUG")

      delete "/onlylogs/queries/#{query["id"]}", params: {log_file_path: @encrypted_path}

      assert_response :no_content

      get "/onlylogs/queries", params: {log_file_path: @encrypted_path}
      assert_equal [], response.parsed_body["queries"]
    end

    test "destroy returns not found for an unknown id" do
      delete "/onlylogs/queries/123456", params: {log_file_path: @encrypted_path}

      assert_response :not_found
    end

    # log file resolution

    test "returns bad request when log_file_path is missing" do
      get "/onlylogs/queries"

      assert_response :bad_request
    end

    test "returns bad request for a tampered encrypted path" do
      get "/onlylogs/queries", params: {log_file_path: "tampered_garbage"}

      assert_response :bad_request
      assert_predicate response.parsed_body["error"], :present?
    end

    test "returns forbidden for a path outside the permitted patterns" do
      get "/onlylogs/queries", params: {log_file_path: SecureFilePath.encrypt("/etc/passwd")}

      assert_response :forbidden
      assert_predicate response.parsed_body["error"], :present?
    end

    test "create is refused for a path outside the permitted patterns" do
      post "/onlylogs/queries",
        params: {log_file_path: SecureFilePath.encrypt("/etc/passwd"), name: "Sneaky", filter: "x"},
        as: :json

      assert_response :forbidden
    end

    test "queries are shared between log files in the same directory" do
      create_query(name: "Shared", filter: "ERROR")

      sibling_path = ::File.join(@temp_dir, "sidekiq.log")
      ::File.write(sibling_path, "other log content\n")

      get "/onlylogs/queries", params: {log_file_path: SecureFilePath.encrypt(sibling_path)}

      assert_response :success
      assert_equal ["Shared"], response.parsed_body["queries"].map { |q| q["name"] }
    end

    test "queries are basic auth protected when basic auth is enabled" do
      Onlylogs.configure do |config|
        config.disable_basic_authentication = false
        config.basic_auth_user = "user"
        config.basic_auth_password = "password"
      end

      get "/onlylogs/queries", params: {log_file_path: @encrypted_path}
      assert_response :unauthorized

      auth_header = {
        "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("user", "password")
      }
      get "/onlylogs/queries", params: {log_file_path: @encrypted_path}, headers: auth_header
      assert_response :success
    end

    private

    def create_query(attributes)
      post "/onlylogs/queries", params: attributes.merge(log_file_path: @encrypted_path), as: :json
      assert_response :created

      response.parsed_body
    end
  end
end
