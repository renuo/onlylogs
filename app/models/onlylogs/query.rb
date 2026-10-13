# frozen_string_literal: true

module Onlylogs
  # Abstract: QueryDatabase connects one subclass per log directory.
  class Query < ActiveRecord::Base
    self.abstract_class = true
    self.table_name = "queries"

    normalizes :name, with: ->(name) { name.strip }

    normalizes :filter, with: ->(filter) { filter.to_s }, apply_to_nil: true
    normalizes :regexp_mode, with: ->(regexp_mode) { regexp_mode || false }, apply_to_nil: true
    normalizes :case_insensitive, with: ->(case_insensitive) { case_insensitive || false }, apply_to_nil: true

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
