# frozen_string_literal: true

require "digest"
require "fileutils"

module Onlylogs
  # A SQLite database kept in each log directory, shared by all log files in it.
  #
  # The models of one directory share its connection, so a transaction spans all of them.
  #
  # Migrations are blocks run in order, tracked by SQLite's user_version: append
  # new ones, never edit or reorder shipped ones.
  class DirectoryDatabase
    class UnavailableError < Onlylogs::Error; end

    CONNECTION_TIMEOUT = 5_000

    attr_reader :file_name

    def initialize(file_name, migrations:)
      @file_name = file_name
      @migrations = migrations
      @connection_names = Set.new
      @current_connection_names = {}
      @models = {}
      @mutex = Mutex.new
    end

    # A subclass of +base+ connected to the database of this log file's directory.
    # Without +create+, a directory that has no database yet returns nil instead of getting one.
    def model(base, log_file_path, create: true)
      path = database_path(log_file_path)

      @mutex.synchronize do
        connection_name = connection_name_for(path, create: create)
        next unless connection_name

        @models[[connection_name, base]] ||= build_model(base, connection_name)
      end
    end

    def clear_connections
      @mutex.synchronize do
        @connection_names.each { |name| ActiveRecord::Base.connection_handler.remove_connection_pool(name) }
        @connection_names.clear
        @current_connection_names.clear
        @models.clear
      end
    end

    private

    def database_path(log_file_path)
      directory = ::File.dirname(::File.expand_path(log_file_path.to_s))

      ::File.join(directory, Onlylogs.configuration.database_dir, file_name)
    end

    # A database file that was deleted or replaced (a purged or renamed project, say) gets a pool of its own.
    # The old pool still points at the old file and is left to the pool reaper, so a connection in use,
    # like the one a test transaction holds, is never pulled away.
    def connection_name_for(path, create:)
      create_database(path) if create
      identity = file_identity(path)
      return unless identity

      # Pools are keyed by name; digest the path so it never leaks into error messages.
      connection_name = "#{self.class.name}::D#{Digest::SHA256.hexdigest([path, *identity].join(":"))[0, 12]}"
      connect(path, connection_name) unless @connection_names.include?(connection_name)

      previous = @current_connection_names[path]
      @models.delete_if { |(name, _base), _model| name == previous } if previous && previous != connection_name
      @current_connection_names[path] = connection_name
    end

    def connect(path, connection_name)
      pool = ActiveRecord::Base.connection_handler.establish_connection(
        {adapter: "sqlite3", database: path, timeout: CONNECTION_TIMEOUT}, owner_name: connection_name
      )
      pool.with_connection { |connection| migrate(connection) }
      @connection_names << connection_name
    end

    def file_identity(path)
      stat = ::File.stat(path)
      [stat.dev, stat.ino]
    rescue SystemCallError
      nil
    end

    def create_database(path)
      FileUtils.mkdir_p(::File.dirname(path))
      FileUtils.touch(path) unless ::File.exist?(path)
    rescue SystemCallError
      raise UnavailableError, "the log directory is not writable"
    end

    def build_model(base, connection_name)
      model = Class.new(base) do
        def self.model_name = ActiveModel::Name.new(self, nil, superclass.name)
      end
      model_class_name = "#{base.name}::#{connection_name.demodulize}"
      model.define_singleton_method(:name) { model_class_name }
      model.connection_specification_name = connection_name
      model
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
