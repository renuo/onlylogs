require "test_helper"
require "fileutils"
require "tmpdir"

class Onlylogs::QueryTest < ActiveSupport::TestCase
  setup do
    @temp_dir = Dir.mktmpdir
    @log_file_path = File.join(@temp_dir, "test.log")
    File.write(@log_file_path, "test log content")

    # Clear any existing connections
    Onlylogs::Query::Database.clear_connections
  end

  teardown do
    Onlylogs::Query::Database.clear_connections
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
  end

  test "create a new query" do
    query = Onlylogs::Query.create(
      @log_file_path,
      name: "Test Query",
      filter: "ERROR",
      regexp_mode: false
    )

    assert_not_nil query.id
    assert_equal "Test Query", query.name
    assert_equal "ERROR", query.filter
    assert_equal false, query.regexp_mode
    assert_not_nil query.created_at
    assert_not_nil query.updated_at
  end

  test "retrieve a query by id" do
    created_query = Onlylogs::Query.create(
      @log_file_path,
      name: "Find Me",
      filter: "WARN",
      regexp_mode: true
    )

    found_query = Onlylogs::Query.find(@log_file_path, created_query.id)

    assert_not_nil found_query
    assert_equal created_query.id, found_query.id
    assert_equal "Find Me", found_query.name
    assert_equal "WARN", found_query.filter
    assert_equal true, found_query.regexp_mode
  end

  test "list all queries for a log file" do
    Onlylogs::Query.create(@log_file_path, name: "Query 1", filter: "ERROR")
    Onlylogs::Query.create(@log_file_path, name: "Query 2", filter: "WARN")
    Onlylogs::Query.create(@log_file_path, name: "Query 3", filter: "INFO")

    queries = Onlylogs::Query.all(@log_file_path)

    assert_equal 3, queries.length
    assert_equal ["Query 1", "Query 2", "Query 3"], queries.map(&:name).sort
  end

  test "delete a query" do
    query = Onlylogs::Query.create(@log_file_path, name: "To Delete", filter: "DEBUG")

    query.delete(@log_file_path)

    found = Onlylogs::Query.find(@log_file_path, query.id)
    assert_nil found
  end

  test "validate query name is required" do
    assert_raises ArgumentError, "Query name cannot be empty" do
      Onlylogs::Query.create(@log_file_path, name: "", filter: "ERROR")
    end
  end

  test "validate query name length" do
    long_name = "a" * 256
    assert_raises ArgumentError, "Query name is too long" do
      Onlylogs::Query.create(@log_file_path, name: long_name, filter: "ERROR")
    end
  end

  test "validate regexp syntax" do
    assert_raises Onlylogs::Query::InvalidRegexpError do
      Onlylogs::Query.create(
        @log_file_path,
        name: "Bad Regex",
        filter: "[invalid",
        regexp_mode: true
      )
    end
  end

  test "allow empty filter with regexp mode off" do
    query = Onlylogs::Query.create(
      @log_file_path,
      name: "Empty Filter",
      filter: "",
      regexp_mode: false
    )

    assert_equal "", query.filter
  end

  test "convert query to hash" do
    query = Onlylogs::Query.create(
      @log_file_path,
      name: "Hash Test",
      filter: "ERROR",
      regexp_mode: true
    )

    hash = query.to_h

    assert hash.is_a?(Hash)
    assert_equal query.id, hash[:id]
    assert_equal "Hash Test", hash[:name]
    assert_equal "ERROR", hash[:filter]
    assert_equal true, hash[:regexp_mode]
    assert_not_nil hash[:created_at]
    assert_not_nil hash[:updated_at]
  end

  test "database is created in correct directory" do
    Onlylogs::Query.create(@log_file_path, name: "Test", filter: "ERROR")

    queries_dir = File.join(@temp_dir, ".onlylogs")
    db_file = File.join(queries_dir, "queries.db")

    assert File.directory?(queries_dir), "Queries directory should exist"
    assert File.exist?(db_file), "Database file should exist"
  end
end
