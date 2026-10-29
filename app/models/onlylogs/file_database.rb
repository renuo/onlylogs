# frozen_string_literal: true

require "digest"
require "fileutils"

module Onlylogs
  # Keeps the models under an abstract class in SQLite files picked at runtime, a database per file:
  #
  #   class NotesRecord < ActiveRecord::Base
  #     self.abstract_class = true
  #     include Onlylogs::FileDatabase
  #
  #     database_migrations ->(connection) { connection.create_table(:notes) { |t| t.string :title } }
  #   end
  #
  #   class Note < NotesRecord; end
  #
  #   NotesRecord.with_database("path/to/notes.db") { Note.all.to_a }
  #
  # Outside with_database the models have no connection, so Note.all raises.
  #
  # Each file is a shard of the class, connected on first use. A file deleted or replaced since (a purged or renamed
  # directory, say) has another inode and so a shard of its own: the old shard's idle connections are reaped, and a
  # connection in use, like a test transaction's, is never pulled away.
  #
  # Migrations are blocks run in order, tracked by SQLite's user_version: append new ones, never edit or reorder
  # shipped ones.
  module FileDatabase
    extend ActiveSupport::Concern

    class UnavailableError < Onlylogs::Error; end

    CONNECTION_TIMEOUT = 5_000

    included do
      self.connection_class = true
      self.connection_specification_name = name

      @database_migrations = []
      @database_shards = Set.new
      @database_lock = Mutex.new
    end

    class_methods do
      def database_migrations(*migrations)
        @database_migrations = migrations
      end

      # Without create, a file that does not exist yields nothing and returns nil.
      def with_database(path, create: true, &)
        path = ::File.expand_path(path.to_s)
        if create
          create_database_file(path)
        elsif !::File.exist?(path)
          return
        end

        connected_to(role: ActiveRecord.writing_role, shard: database_shard(path), &)
      end

      def clear_database_connections
        @database_lock.synchronize do
          @database_shards.each do |shard|
            connection_handler.remove_connection_pool(connection_specification_name, role: ActiveRecord.writing_role, shard: shard)
          end
          @database_shards.clear
        end
      end

      private

      def create_database_file(path)
        FileUtils.mkdir_p(::File.dirname(path))
        FileUtils.touch(path) unless ::File.exist?(path)
      rescue SystemCallError
        raise UnavailableError, "#{::File.basename(path)} cannot be created"
      end

      def database_shard(path)
        stat = ::File.stat(path)
        # Digested, so the path never leaks into error messages.
        shard = :"file_#{Digest::SHA256.hexdigest([path, stat.dev, stat.ino].join(":"))[0, 16]}"

        @database_lock.synchronize do
          unless @database_shards.include?(shard)
            pool = connection_handler.establish_connection(
              {adapter: "sqlite3", database: path, timeout: CONNECTION_TIMEOUT},
              owner_name: self, role: ActiveRecord.writing_role, shard: shard
            )
            pool.with_connection { |connection| migrate_database(connection) }
            @database_shards << shard
          end
        end

        shard
      end

      # Transactions are IMMEDIATE, so the version is read under the write lock and
      # concurrent workers cannot run the same migration twice.
      def migrate_database(connection)
        return if database_version(connection) >= @database_migrations.size

        connection.transaction do
          version = database_version(connection)
          @database_migrations.drop(version).each { |migration| migration.call(connection) }
          connection.execute("PRAGMA user_version = #{@database_migrations.size}")
        end
      end

      def database_version(connection)
        connection.select_value("PRAGMA user_version").to_i
      end
    end
  end
end
