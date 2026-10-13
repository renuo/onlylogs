# frozen_string_literal: true

require "digest"
require "fileutils"

module Onlylogs
  # A SQLite database kept in each log directory, shared by all log files in it.
  #
  # Migrations are blocks run in order, tracked by SQLite's user_version: append
  # new ones, never edit or reorder shipped ones.
  class DirectoryDatabase
    class UnavailableError < Onlylogs::Error; end

    CONNECTION_TIMEOUT = 5_000

    Entry = Struct.new(:model, :file_identity)

    attr_reader :file_name

    def initialize(file_name, migrations:)
      @file_name = file_name
      @migrations = migrations
      @models = {}
      @mutex = Mutex.new
    end

    # A subclass of +base+ connected to the database of this log file's directory.
    def model(base, log_file_path)
      path = database_path(log_file_path)
      key = [path, base]

      @mutex.synchronize do
        entry = @models[key]
        next entry.model if entry && entry.file_identity == file_identity(path)

        # The directory was deleted or replaced (a purged or renamed project, say):
        # the open connection still points at the old file.
        entry&.model&.remove_connection
        model = build_model(base, path)
        @models[key] = Entry.new(model, file_identity(path))
        model
      end
    end

    def clear_connections
      @mutex.synchronize do
        @models.each_value { |entry| entry.model.remove_connection }
        @models.clear
      end
    end

    private

    def database_path(log_file_path)
      directory = ::File.dirname(::File.expand_path(log_file_path.to_s))

      ::File.join(directory, Onlylogs.configuration.database_dir, file_name)
    end

    def file_identity(path)
      stat = ::File.stat(path)
      [stat.dev, stat.ino]
    rescue SystemCallError
      nil
    end

    def build_model(base, path)
      prepare_directory(::File.dirname(path))

      model = Class.new(base) do
        def self.model_name = ActiveModel::Name.new(self, nil, superclass.name)
      end

      # Pools are keyed by class name; digest the path so it never leaks into error messages.
      connection_name = "#{base.name}::D#{Digest::SHA256.hexdigest(path)[0, 12]}"
      model.define_singleton_method(:name) { connection_name }

      model.establish_connection(adapter: "sqlite3", database: path, timeout: CONNECTION_TIMEOUT)
      model.with_connection { |connection| migrate(connection) }

      model
    end

    def prepare_directory(directory)
      FileUtils.mkdir_p(directory)
    rescue SystemCallError
      raise UnavailableError, "the log directory is not writable"
    end

    # Transactions are IMMEDIATE, so the version is read under the write lock and
    # concurrent workers cannot run the same migration twice.
    def migrate(connection)
      return if schema_version(connection) >= @migrations.size

      connection.transaction do
        version = schema_version(connection)
        @migrations.drop(version).each { |migration| migration.call(connection) }
        connection.execute("PRAGMA user_version = #{@migrations.size}")
      end
    end

    def schema_version(connection)
      connection.select_value("PRAGMA user_version").to_i
    end
  end
end
