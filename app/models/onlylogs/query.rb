# frozen_string_literal: true

module Onlylogs
  # A saved query.
  #
  # Abstract, because saved queries live in a SQLite database per log directory
  # rather than in the host application's database. QueryDatabase builds one
  # connected subclass per directory; reach them through Onlylogs::File#queries.
  class Query < ActiveRecord::Base
    self.abstract_class = true

    normalizes :name, with: ->(name) { name.strip }

    # Both columns are NOT NULL with a default, so an explicit null in the
    # request body would otherwise reach the database as a violation - a 500
    # where the client should be told what it sent was wrong, or nothing at all.
    normalizes :filter, with: ->(filter) { filter.to_s }, apply_to_nil: true
    normalizes :regexp_mode, with: ->(regexp_mode) { regexp_mode || false }, apply_to_nil: true

    validates :name, presence: true, length: {maximum: 255}, uniqueness: {case_sensitive: false}
    validate :filter_must_be_a_valid_regexp

    private

    def filter_must_be_a_valid_regexp
      return unless regexp_mode?
      return if filter.blank?

      Regexp.new(filter)
    rescue RegexpError => e
      errors.add(:filter, "is not a valid regexp: #{e.message}")
    end
  end
end
