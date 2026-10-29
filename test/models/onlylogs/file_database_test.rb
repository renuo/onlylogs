require "test_helper"
require "fileutils"
require "tmpdir"

class Onlylogs::FileDatabaseTest < ActiveSupport::TestCase
  # The temp database is deleted in teardown, before a rollback could run.
  self.use_transactional_tests = false

  CALLS = []

  class NotesRecord < ActiveRecord::Base
    self.abstract_class = true
    include Onlylogs::FileDatabase

    database_migrations(
      ->(connection) {
        CALLS << :create_notes
        connection.create_table(:notes) { |t| t.string :title }
        connection.create_table(:tags) { |t| t.string :label }
      },
      ->(connection) {
        CALLS << :add_body
        connection.add_column(:notes, :body, :text)
      }
    )
  end

  class Note < NotesRecord
    self.table_name = "notes"
  end

  class Tag < NotesRecord
    self.table_name = "tags"
  end

  setup do
    @temp_dir = Dir.mktmpdir
    @path = File.join(@temp_dir, ".onlylogs", "notes.db")
    CALLS.clear
  end

  teardown do
    NotesRecord.clear_database_connections
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
  end

  test "models work inside with_database and raise outside it" do
    note = NotesRecord.with_database(@path) { Note.create!(title: "Hello", body: "World") }

    assert_equal "World", NotesRecord.with_database(@path) { note.reload.body }
    assert_raises(ActiveRecord::ConnectionNotDefined) { Note.count }
  end

  test "with_database returns what its block returns" do
    assert_equal 0, NotesRecord.with_database(@path) { Note.count }
  end

  test "run every migration on a new database" do
    NotesRecord.with_database(@path) { Note.count }

    assert_equal [:create_notes, :add_body], CALLS
    assert_equal 2, user_version
  end

  test "run only the migrations a database has not seen yet" do
    SQLite3::Database.new(prepare_path) do |db|
      db.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, title varchar)")
      db.execute("CREATE TABLE tags (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, label varchar)")
      db.execute("INSERT INTO notes (title) VALUES ('Kept')")
      db.execute("PRAGMA user_version = 1")
    end

    titles = NotesRecord.with_database(@path) { Note.pluck(:title) }

    assert_equal [:add_body], CALLS
    assert_equal ["Kept"], titles
    assert_equal 2, user_version
  end

  test "do not migrate again on the next connection" do
    NotesRecord.with_database(@path) { Note.count }
    NotesRecord.clear_database_connections
    CALLS.clear

    NotesRecord.with_database(@path) { Note.count }

    assert_empty CALLS
  end

  test "a failing migration leaves the database at its previous version" do
    SQLite3::Database.new(prepare_path) do |db|
      db.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, title varchar, body text)")
      db.execute("CREATE TABLE tags (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, label varchar)")
      db.execute("PRAGMA user_version = 1")
    end

    assert_raises(ActiveRecord::StatementInvalid) { NotesRecord.with_database(@path) { Note.count } }

    assert_equal 1, user_version
  end

  test "the models of one database share a connection, so a transaction spans them" do
    NotesRecord.with_database(@path) do
      assert_raises(RuntimeError) do
        NotesRecord.transaction do
          Note.create!(title: "Hello")
          Tag.create!(label: "greeting")
          raise "boom"
        end
      end

      assert_equal 0, Note.count
      assert_equal 0, Tag.count
    end
  end

  test "each file is a database of its own" do
    other_path = File.join(@temp_dir, "other", "notes.db")
    NotesRecord.with_database(@path) { Note.create!(title: "Here") }

    assert_empty NotesRecord.with_database(other_path) { Note.pluck(:title) }
    assert_equal ["Here"], NotesRecord.with_database(@path) { Note.pluck(:title) }
  end

  test "databases nest" do
    other_path = File.join(@temp_dir, "other", "notes.db")

    titles = NotesRecord.with_database(@path) do
      Note.create!(title: "Outer")
      inner = NotesRecord.with_database(other_path) { Note.create!(title: "Inner") && Note.pluck(:title) }
      [inner, Note.pluck(:title)]
    end

    assert_equal [["Inner"], ["Outer"]], titles
  end

  test "without create, a missing file yields nothing and is left alone" do
    assert_nil NotesRecord.with_database(@path, create: false) { flunk "should not yield" }
    assert_not File.exist?(File.dirname(@path))

    NotesRecord.with_database(@path) { Note.create!(title: "Hello") }
    assert_equal ["Hello"], NotesRecord.with_database(@path, create: false) { Note.pluck(:title) }
  end

  test "a file replaced on disk is connected afresh" do
    NotesRecord.with_database(@path) { Note.create!(title: "Gone") }

    FileUtils.rm_rf(File.dirname(@path))

    assert_nil NotesRecord.with_database(@path, create: false) { Note.count }
    assert_empty NotesRecord.with_database(@path) { Note.pluck(:title) }
  end

  test "raise unavailable when the file cannot be created" do
    File.write(File.join(@temp_dir, ".onlylogs"), "a file where the directory should be")

    assert_raises(Onlylogs::FileDatabase::UnavailableError) do
      NotesRecord.with_database(@path) { Note.count }
    end
  end

  private

  def prepare_path
    FileUtils.mkdir_p(File.dirname(@path))
    @path
  end

  def user_version
    SQLite3::Database.new(@path) { |db| return db.get_first_value("PRAGMA user_version") }
  end
end
