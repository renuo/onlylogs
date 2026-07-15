# frozen_string_literal: true

require "sqlite3"
require "fileutils"
require "time"

module Onlylogs
  class Query
    attr_reader :id, :created_at, :updated_at
    attr_accessor :name, :filter, :regexp_mode

    class InvalidRegexpError < StandardError; end
    class NotFoundError < StandardError; end

    def initialize(name:, filter:, id: nil, regexp_mode: false, created_at: nil, updated_at: nil)
      @id = id
      @name = name
      @filter = filter
      @regexp_mode = !!regexp_mode
      @created_at = created_at || self.class.now
      @updated_at = updated_at || self.class.now
    end

    # Find a saved query by id for the directory containing this log file.
    def self.find(log_file_path, id)
      db = Database.for_file(log_file_path)

      row = db.execute(
        "SELECT id, name, filter, regexp_mode, created_at, updated_at FROM queries WHERE id = ?",
        [id]
      ).first

      row ? from_row(row) : nil
    end

    # Get all saved queries shared by files in this log file's directory.
    def self.all(log_file_path)
      db = Database.for_file(log_file_path)

      rows = db.execute(
        "SELECT id, name, filter, regexp_mode, created_at, updated_at FROM queries ORDER BY updated_at DESC"
      )

      rows.map { |row| from_row(row) }
    end

    # Create and persist a new saved query.
    def self.create(log_file_path, name:, filter:, regexp_mode: false)
      new(
        name: name,
        filter: filter,
        regexp_mode: regexp_mode
      ).save(log_file_path)
    end

    def save(log_file_path)
      self.class.validate_name!(@name)
      self.class.validate_filter!(@filter, @regexp_mode)

      db = Database.for_file(log_file_path)
      now = self.class.now
      @updated_at = now

      if @id
        update_existing(db, now)
      else
        insert_new(db, now)
      end

      self
    end

    def delete(log_file_path)
      return self unless @id

      db = Database.for_file(log_file_path)

      db.execute(
        "DELETE FROM queries WHERE id = ?",
        [@id]
      )

      raise NotFoundError, "Query with id #{@id} was not found" if db.changes.zero?

      @id = nil

      self
    end

    def to_h
      {
        id: @id,
        name: @name,
        filter: @filter,
        regexp_mode: @regexp_mode,
        created_at: @created_at,
        updated_at: @updated_at
      }
    end

    def self.validate_name!(name)
      normalized_name = name.to_s.strip

      raise ArgumentError, "Query name cannot be empty" if normalized_name.empty?
      raise ArgumentError, "Query name is too long (max 255 characters)" if normalized_name.length > 255
    end

    def self.validate_filter!(filter, regexp_mode)
      return if filter.to_s.empty?
      return unless regexp_mode

      Regexp.new(filter)
    rescue RegexpError => e
      raise InvalidRegexpError, "Invalid regexp: #{e.message}"
    end

    def self.from_row(row)
      new(
        id: row[0],
        name: row[1],
        filter: row[2],
        regexp_mode: row[3].to_i == 1,
        created_at: row[4],
        updated_at: row[5]
      )
    end

    def self.now
      Time.now.utc.iso8601
    end

    private

    def update_existing(db, now)
      db.execute(
        <<~SQL,
          UPDATE queries
          SET name = ?,
              filter = ?,
              regexp_mode = ?,
              updated_at = ?
          WHERE id = ?
        SQL
        [
          @name.to_s.strip,
          @filter.to_s,
          @regexp_mode ? 1 : 0,
          now,
          @id
        ]
      )

      raise NotFoundError, "Query with id #{@id} was not found" if db.changes.zero?
    end

    def insert_new(db, now)
      @created_at ||= now

      db.execute(
        <<~SQL,
          INSERT INTO queries
            (name, filter, regexp_mode, created_at, updated_at)
          VALUES
            (?, ?, ?, ?, ?)
        SQL
        [
          @name.to_s.strip,
          @filter.to_s,
          @regexp_mode ? 1 : 0,
          @created_at,
          now
        ]
      )

      @id = db.last_insert_row_id
    end

    # Handles SQLite connections for saved queries.
    #
    # Important:
    # The database is stored per log directory, not per exact log file.
    # For example, these two files share the same saved queries database:
    #
    #   /var/log/my-app/production.log
    #   /var/log/my-app/sidekiq.log
    #
    class Database
      @connections = {}
      @mutex = Mutex.new

      class << self
        def for_file(log_file_path)
          key = connection_key(log_file_path)

          @mutex.synchronize do
            @connections[key] ||= connect(key)
          end
        end

        # Useful in tests and during cleanup.
        def clear_connections
          @mutex.synchronize do
            @connections.each_value(&:close)
            @connections.clear
          end
        end

        private

        def connection_key(log_file_path)
          ::File.expand_path(log_file_path.to_s)
        end

        def connect(log_file_path)
          db_path = ::File.join(::File.dirname(log_file_path), Onlylogs.configuration.queries_database_dir, "queries.db")
          FileUtils.mkdir_p(::File.dirname(db_path))

          db = SQLite3::Database.new(db_path)
          db.results_as_hash = false
          db.busy_timeout = 5000
          create_tables(db)
          db
        end

        def database_path(log_file_path)
          log_dir = ::File.dirname(log_file_path)
          queries_dir = ::File.join(log_dir, Onlylogs.configuration.queries_database_dir)

          ::File.join(queries_dir, "queries.db")
        end

        def create_tables(db)
          db.execute <<~SQL
            CREATE TABLE IF NOT EXISTS queries (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL UNIQUE,
              filter TEXT NOT NULL,
              regexp_mode INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          SQL

          db.execute <<~SQL
            CREATE INDEX IF NOT EXISTS index_queries_on_lower_name
            ON queries (LOWER(name))
          SQL
        end
      end
    end
  end
end
