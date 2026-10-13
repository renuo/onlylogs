# frozen_string_literal: true

require "digest"
require "fileutils"

module Onlylogs
  # One SQLite database per log directory, shared by all log files in it.
  class QueryDatabase
    class UnavailableError < Onlylogs::Error; end

    TABLE_NAME = "queries"
    CONNECTION_TIMEOUT = 5_000

    Entry = Struct.new(:model, :file_identity)

    @models = {}
    @mutex = Mutex.new

    class << self
      def model_for(log_file_path)
        path = database_path(log_file_path)

        @mutex.synchronize do
          entry = @models[path]
          next entry.model if entry && entry.file_identity == file_identity(path)

          # The directory was deleted or replaced (a purged or renamed project, say):
          # the open connection still points at the old file.
          entry&.model&.remove_connection
          model = build_model(path)
          @models[path] = Entry.new(model, file_identity(path))
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

      def file_identity(path)
        stat = ::File.stat(path)
        [stat.dev, stat.ino]
      rescue SystemCallError
        nil
      end

      def database_path(log_file_path)
        directory = ::File.dirname(::File.expand_path(log_file_path.to_s))

        ::File.join(directory, Onlylogs.configuration.queries_database_dir, "#{TABLE_NAME}.db")
      end

      def build_model(database_path)
        prepare_directory(::File.dirname(database_path))

        model = Class.new(Query) do
          self.table_name = TABLE_NAME

          def self.model_name = ActiveModel::Name.new(self, nil, "Onlylogs::Query")
        end

        # Pools are keyed by class name; digest the path so it never leaks into error messages.
        connection_name = "Onlylogs::Query::D#{Digest::SHA256.hexdigest(database_path)[0, 12]}"
        model.define_singleton_method(:name) { connection_name }

        model.establish_connection(adapter: "sqlite3", database: database_path, timeout: CONNECTION_TIMEOUT)
        create_table(model)

        model
      end

      def prepare_directory(directory)
        FileUtils.mkdir_p(directory)
      rescue SystemCallError
        raise UnavailableError, "Saved queries are unavailable: the log directory is not writable"
      end

      def create_table(model)
        model.with_connection do |connection|
          connection.create_table(TABLE_NAME, if_not_exists: true) do |t|
            t.string :name, null: false
            t.string :filter, null: false, default: ""
            t.boolean :regexp_mode, null: false, default: false
            t.boolean :case_insensitive, null: false, default: false
            t.timestamps

            t.index "LOWER(name)", unique: true, name: "index_queries_on_lower_name"
          end

          upgrade_table(connection)
        end
      end

      def upgrade_table(connection)
        return if connection.column_exists?(TABLE_NAME, :case_insensitive)

        connection.add_column(TABLE_NAME, :case_insensitive, :boolean, null: false, default: false)
      rescue ActiveRecord::StatementInvalid
        raise unless connection.column_exists?(TABLE_NAME, :case_insensitive)
      end
    end
  end
end
