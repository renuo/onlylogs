require "test_helper"
require "fileutils"
require "tmpdir"

class Onlylogs::QueryTest < ActiveSupport::TestCase
  # Each test works against a throwaway SQLite database in a temp directory that
  # teardown deletes. Transactional fixtures would reconnect to those pools
  # afterwards to roll back, by which point the files are gone.
  self.use_transactional_tests = false

  setup do
    @temp_dir = Dir.mktmpdir
    @log_file_path = File.join(@temp_dir, "test.log")
    File.write(@log_file_path, "test log content")

    # Clear any existing connections
    Onlylogs::QueryDatabase.clear_connections

    @log_file = Onlylogs::File.new(@log_file_path)
  end

  teardown do
    Onlylogs::QueryDatabase.clear_connections
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
  end

  test "create a new query" do
    query = @log_file.queries.create(
      name: "Test Query",
      filter: "ERROR",
      regexp_mode: false
    )

    assert_predicate query, :persisted?
    assert_equal "Test Query", query.name
    assert_equal "ERROR", query.filter
    assert_equal false, query.regexp_mode
    assert_not_nil query.created_at
    assert_not_nil query.updated_at
  end

  test "retrieve a query by id" do
    created_query = @log_file.queries.create(
      name: "Find Me",
      filter: "WARN",
      regexp_mode: true
    )

    found_query = @log_file.queries.find(created_query.id)

    assert_equal created_query.id, found_query.id
    assert_equal "Find Me", found_query.name
    assert_equal "WARN", found_query.filter
    assert_equal true, found_query.regexp_mode
  end

  test "find raises when the query does not exist" do
    assert_raises ActiveRecord::RecordNotFound do
      @log_file.queries.find(123_456)
    end
  end

  test "find_by returns nil when the query does not exist" do
    assert_nil @log_file.queries.find_by(id: 123_456)
  end

  test "list all queries for a log file" do
    @log_file.queries.create(name: "Query 1", filter: "ERROR")
    @log_file.queries.create(name: "Query 2", filter: "WARN")
    @log_file.queries.create(name: "Query 3", filter: "INFO")

    assert_equal ["Query 1", "Query 2", "Query 3"], @log_file.queries.pluck(:name).sort
  end

  test "list the most recently updated queries first" do
    oldest = @log_file.queries.create(name: "Oldest", filter: "ERROR")
    newest = @log_file.queries.create(name: "Newest", filter: "WARN")

    oldest.touch

    assert_equal [oldest.id, newest.id], @log_file.queries.ids
  end

  test "log files in the same directory share their queries" do
    sibling_path = File.join(@temp_dir, "sidekiq.log")
    File.write(sibling_path, "other log content")

    @log_file.queries.create(name: "Shared", filter: "ERROR")

    assert_equal ["Shared"], Onlylogs::File.new(sibling_path).queries.pluck(:name)
  end

  test "log files in different directories keep separate queries" do
    other_dir = Dir.mktmpdir
    other_log_path = File.join(other_dir, "other.log")
    File.write(other_log_path, "other log content")

    @log_file.queries.create!(name: "Mine", filter: "ERROR")
    other_log_file = Onlylogs::File.new(other_log_path)
    other_log_file.queries.create!(name: "Theirs", filter: "WARN")

    assert_equal ["Mine"], @log_file.queries.pluck(:name)
    assert_equal ["Theirs"], other_log_file.queries.pluck(:name)
  ensure
    FileUtils.remove_entry(other_dir) if other_dir && File.directory?(other_dir)
  end

  test "update a query" do
    query = @log_file.queries.create(name: "Before", filter: "ERROR")

    assert query.update(name: "After", filter: "WARN", regexp_mode: true)

    reloaded = @log_file.queries.find(query.id)
    assert_equal "After", reloaded.name
    assert_equal "WARN", reloaded.filter
    assert_equal true, reloaded.regexp_mode
  end

  test "cast regexp_mode from a string" do
    query = @log_file.queries.create(name: "Casting", filter: "ERROR", regexp_mode: true)

    query.update(regexp_mode: "false")

    assert_equal false, @log_file.queries.find(query.id).regexp_mode
  end

  test "destroy a query" do
    query = @log_file.queries.create(name: "To Delete", filter: "DEBUG")

    query.destroy

    assert_predicate query, :destroyed?
    assert_nil @log_file.queries.find_by(id: query.id)
  end

  test "validate query name is required" do
    query = @log_file.queries.create(name: "", filter: "ERROR")

    assert_not_predicate query, :persisted?
    assert_includes query.errors[:name], "can't be blank"
  end

  test "validate query name length" do
    query = @log_file.queries.create(name: "a" * 256, filter: "ERROR")

    assert_not_predicate query, :persisted?
    assert_includes query.errors[:name], "is too long (maximum is 255 characters)"
  end

  test "validate regexp syntax" do
    query = @log_file.queries.create(name: "Bad Regex", filter: "[invalid", regexp_mode: true)

    assert_not_predicate query, :persisted?
    assert_predicate query.errors[:filter], :any?
  end

  test "reject a duplicate query name regardless of case" do
    @log_file.queries.create(name: "Duplicate", filter: "ERROR")

    query = @log_file.queries.create(name: "duplicate", filter: "WARN")

    assert_not_predicate query, :persisted?
    assert_includes query.errors[:name], "has already been taken"
  end

  test "strip whitespace around the name" do
    query = @log_file.queries.create(name: "  Padded  ", filter: "ERROR")

    assert_equal "Padded", query.name
  end

  test "allow empty filter with regexp mode off" do
    query = @log_file.queries.create(
      name: "Empty Filter",
      filter: "",
      regexp_mode: false
    )

    assert_predicate query, :persisted?
    assert_equal "", query.filter
  end

  test "serialize a query as json" do
    query = @log_file.queries.create(
      name: "Hash Test",
      filter: "ERROR",
      regexp_mode: true
    )

    json = query.as_json

    assert_equal query.id, json["id"]
    assert_equal "Hash Test", json["name"]
    assert_equal "ERROR", json["filter"]
    assert_equal true, json["regexp_mode"]
    assert_not_nil json["created_at"]
    assert_not_nil json["updated_at"]
  end

  test "database is created in correct directory" do
    @log_file.queries.create(name: "Test", filter: "ERROR")

    queries_dir = File.join(@temp_dir, ".onlylogs")
    db_file = File.join(queries_dir, "queries.db")

    assert File.directory?(queries_dir), "Queries directory should exist"
    assert File.exist?(db_file), "Database file should exist"
  end
end
