# frozen_string_literal: true

require "test_helper"

module Onlylogs
  class ApplicationHelperTest < ActionView::TestCase
    include ApplicationHelper

    test "log_file_label returns relative path when file is under Rails.root" do
      file = Rails.root.join("log", "production.log").to_s
      assert_equal "log/production.log", log_file_label(file)
    end

    test "log_file_label returns basename when file is outside Rails.root" do
      file = Onlylogs::Engine.root.join("test", "fixtures", "files", "sample.log").to_s
      assert_equal "sample.log", log_file_label(file)
    end
  end
end
