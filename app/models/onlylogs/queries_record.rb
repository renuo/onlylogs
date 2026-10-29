# frozen_string_literal: true

module Onlylogs
  # Saved queries live in a database kept in each log directory, shared by all log files in it:
  # see File#with_database.
  class QueriesRecord < ActiveRecord::Base
    self.abstract_class = true
    include FileDatabase

    database_migrations(
      ->(connection) {
        connection.create_table(:queries, if_not_exists: true) do |t|
          t.string :name, null: false
          t.string :filter, null: false, default: ""
          t.boolean :regexp_mode, null: false, default: false
          t.timestamps

          t.index "LOWER(name)", unique: true, name: "index_queries_on_lower_name"
        end
      },
      ->(connection) {
        unless connection.column_exists?(:queries, :case_insensitive)
          connection.add_column(:queries, :case_insensitive, :boolean, null: false, default: false)
        end
      }
    )
  end
end
