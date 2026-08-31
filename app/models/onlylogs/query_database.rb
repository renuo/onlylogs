# frozen_string_literal: true

require "digest"
require "fileutils"

module Onlylogs
  # Saved queries are stored in a SQLite database per log *directory*, not per
  # log file, so these two files share one database:
  #
  #   /var/log/my-app/production.log
  #   /var/log/my-app/sidekiq.log
  #
  # ActiveRecord binds a connection to a class, so this builds and caches one
  # connected Query subclass per directory.
  class QueryDatabase
    # Raised when the database cannot be opened at all - an unwritable log
    # directory, most often. Distinct from Onlylogs::Error so the controller can
    # tell "this log file is gone" from "saved queries are unavailable here".
    class UnavailableError < Onlylogs::Error; end

    TABLE_NAME = "queries"
    CONNECTION_TIMEOUT = 5_000

    @models = {}
    @mutex = Mutex.new

    class << self
      # The Query subclass connected to this log file's directory.
      def model_for(log_file_path)
        path = database_path(log_file_path)

        @mutex.synchronize { @models[path] ||= build_model(path) }
      end

      # Useful in tests and during cleanup. Removes the pools rather than only
      # disconnecting them: a pool left registered with ActiveRecord is still
      # picked up by transactional tests, which then reopen a database file
      # that may already be gone.
      def clear_connections
        @mutex.synchronize do
          @models.each_value(&:remove_connection)
          @models.clear
        end
      end

      private

      def database_path(log_file_path)
        directory = ::File.dirname(::File.expand_path(log_file_path.to_s))

        ::File.join(directory, Onlylogs.configuration.queries_database_dir, "#{TABLE_NAME}.db")
      end

      def build_model(database_path)
        prepare_directory(::File.dirname(database_path))

        model = Class.new(Query) do
          self.table_name = TABLE_NAME

          # Anonymous classes have no name, which ActiveModel needs for error
          # messages and I18n lookups.
          def self.model_name = ActiveModel::Name.new(self, nil, "Onlylogs::Query")
        end

        # ActiveRecord keys connection pools by class name, so every database
        # needs a distinct one or they all end up sharing a single pool. The path
        # is digested rather than embedded: this name reaches clients through
        # exception messages such as RecordNotFound's.
        connection_name = "Onlylogs::Query::D#{Digest::SHA256.hexdigest(database_path)[0, 12]}"
        model.define_singleton_method(:name) { connection_name }

        model.establish_connection(adapter: "sqlite3", database: database_path, timeout: CONNECTION_TIMEOUT)
        create_table(model)

        model
      end

      def prepare_directory(directory)
        FileUtils.mkdir_p(directory)
      rescue SystemCallError
        # A log directory the application can read but not write to - root-owned
        # /var/log, say. The path stays out of the message; it is server detail.
        raise UnavailableError, "Saved queries are unavailable: the log directory is not writable"
      end

      # +if_not_exists+ rather than a check-then-create: the mutex above only
      # covers this process, and separate web workers can reach a new directory
      # at the same time.
      def create_table(model)
        model.with_connection do |connection|
          connection.create_table(TABLE_NAME, if_not_exists: true) do |t|
            t.string :name, null: false, index: {unique: true}
            t.string :filter, null: false, default: ""
            t.boolean :regexp_mode, null: false, default: false
            t.timestamps
          end
        end
      end
    end
  end
end
