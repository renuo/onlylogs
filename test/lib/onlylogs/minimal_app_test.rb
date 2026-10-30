# frozen_string_literal: true

require "test_helper"
require "open3"

module Onlylogs
  # Boots test/minimal_app, which loads none of the Rails frameworks, in its own process: one
  # process can only boot one Rails app.
  class MinimalAppTest < ActiveSupport::TestCase
    ENVIRONMENT = ::File.expand_path("../../minimal_app/config/environment", __dir__)

    def run_in_minimal_app(code)
      Open3.capture2e({"ONLYLOGS_DRAIN_URL" => nil}, RbConfig.ruby, "-e", "require #{ENVIRONMENT.dump}; #{code}")
    end

    test "boots with eager loading and logs through the HttpLogger" do
      output, status = run_in_minimal_app(<<~RUBY)
        raise "not eager loaded" unless Rails.application.config.eager_load
        Rails.logger.info "hello from the minimal app"
      RUBY

      assert status.success?, output
      assert_match "hello from the minimal app", output
    end

    test "loads neither Action Cable nor Active Record" do
      output, status = run_in_minimal_app("puts [defined?(ActionCable), defined?(ActiveRecord)].inspect")

      assert status.success?, output
      assert_match "[nil, nil]", output
    end
  end
end
