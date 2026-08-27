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
