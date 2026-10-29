require "test_helper"
require "fileutils"
require "tmpdir"

class Onlylogs::DirectoryDatabaseTest < ActiveSupport::TestCase
  # The temp database is deleted in teardown, before a rollback could run.
  self.use_transactional_tests = false

  class Note < ActiveRecord::Base
    self.abstract_class = true
    self.table_name = "notes"
  end

  class Tag < ActiveRecord::Base
    self.abstract_class = true
    self.table_name = "tags"
  end

  setup do
    @temp_dir = Dir.mktmpdir
    @log_file_path = File.join(@temp_dir, "test.log")
    File.write(@log_file_path, "test log content")
    @calls = []
  end

  teardown do
    @database&.clear_connections
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
  end

  test "run every migration on a new database" do
    @database = database(create_notes, add_body)

    note = @database.model(Note, @log_file_path).create!(title: "Hello", body: "World")

    assert_equal "World", note.reload.body
    assert_equal [:create_notes, :add_body], @calls
    assert_equal 2, user_version
  end

  test "run only the migrations a database has not seen yet" do
    database(create_notes).model(Note, @log_file_path).create!(title: "Kept")
    @database.clear_connections
    @calls.clear

    @database = database(create_notes, add_body)
    model = @database.model(Note, @log_file_path)

    assert_equal [:add_body], @calls
    assert_equal ["Kept"], model.pluck(:title)
    assert_equal 2, user_version
  end

  test "do not migrate again on the next connection" do
    database(create_notes, add_body).model(Note, @log_file_path)
    @database.clear_connections
    @calls.clear

    @database.model(Note, @log_file_path)

    assert_empty @calls
  end

  test "a failing migration leaves the database at its previous version" do
    database(create_notes).model(Note, @log_file_path)
    @database.clear_connections

    failing = ->(connection) {
      connection.add_column(:notes, :body, :text)
      raise "boom"
    }
    assert_raises(RuntimeError) { database(create_notes, failing).model(Note, @log_file_path) }
    @database.clear_connections

    assert_equal 1, user_version
    model = database(create_notes, add_body).model(Note, @log_file_path)
    assert_includes model.column_names, "body"
  end

  test "the models of one directory share a connection, so a transaction spans them" do
    @database = database(create_notes, create_tags)
    notes = @database.model(Note, @log_file_path)
    tags = @database.model(Tag, @log_file_path)

    assert_raises(RuntimeError) do
      notes.transaction do
        notes.create!(title: "Hello")
        tags.create!(label: "greeting")
        raise "boom"
      end
    end

    assert_equal 0, notes.count
    assert_equal 0, tags.count
    assert_same notes.connection_pool, tags.connection_pool
  end

  test "the same base in another directory gets a database of its own" do
    other_dir = Dir.mktmpdir
    @database = database(create_notes)
    @database.model(Note, @log_file_path).create!(title: "Here")

    assert_empty @database.model(Note, File.join(other_dir, "other.log")).pluck(:title)
    assert_equal ["Here"], @database.model(Note, @log_file_path).pluck(:title)
  ensure
    @database.clear_connections
    FileUtils.remove_entry(other_dir)
  end

  test "without create, a directory without a database returns nil and is left untouched" do
    @database = database(create_notes)

    assert_nil @database.model(Note, @log_file_path, create: false)
    assert_not File.exist?(File.join(@temp_dir, ".onlylogs"))

    @database.model(Note, @log_file_path).create!(title: "Hello")
    assert_equal ["Hello"], @database.model(Note, @log_file_path, create: false).pluck(:title)
  end

  test "a database replaced on disk is connected afresh" do
    @database = database(create_notes)
    @database.model(Note, @log_file_path).create!(title: "Gone")

    FileUtils.rm_rf(File.join(@temp_dir, ".onlylogs"))

    assert_nil @database.model(Note, @log_file_path, create: false)
    assert_empty @database.model(Note, @log_file_path).pluck(:title)
  end

  test "raise unavailable when the directory cannot be created" do
    File.write(File.join(@temp_dir, ".onlylogs"), "a file where the directory should be")

    assert_raises(Onlylogs::DirectoryDatabase::UnavailableError) do
      database(create_notes).model(Note, @log_file_path)
    end
  end

  private

  def database(*migrations)
    @database = Onlylogs::DirectoryDatabase.new("notes.db", migrations: migrations)
  end

  def create_notes
    ->(connection) {
      @calls << :create_notes
      connection.create_table(:notes) { |t| t.string :title }
    }
  end

  def create_tags
    ->(connection) { connection.create_table(:tags) { |t| t.string :label } }
  end

  def add_body
    ->(connection) {
      @calls << :add_body
      connection.add_column(:notes, :body, :text)
    }
  end

  def user_version
    SQLite3::Database.new(File.join(@temp_dir, ".onlylogs", "notes.db")) do |db|
      return db.get_first_value("PRAGMA user_version")
    end
  end
end
