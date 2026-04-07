# frozen_string_literal: true

require "test_helper"

module Onlylogs
  class FormatterTest < ActiveSupport::TestCase
    def setup
      @formatter = Onlylogs::Formatter.new
      @time = Time.zone.now
    end

    test "formats a normal log message" do
      result = @formatter.call("INFO", @time, nil, "Hello world")
      assert_includes result, "Hello world"
      assert_includes result, "I"
    end

    test "filters out Onlylogs::LogsChannel messages" do
      result = @formatter.call("INFO", @time, nil, "Onlylogs::LogsChannel is streaming")
      assert_nil result
    end

    test "denylist defaults to empty array" do
      assert_equal [], @formatter.denylist
    end

    test "filters messages matching denylist patterns" do
      @formatter.denylist = [/password/i, /secret_token/]

      assert_nil @formatter.call("INFO", @time, nil, "User changed Password successfully")
      assert_nil @formatter.call("DEBUG", @time, nil, "secret_token=abc123")
    end

    test "allows messages not matching denylist patterns" do
      @formatter.denylist = [/password/i]

      result = @formatter.call("INFO", @time, nil, "User logged in")
      assert_not_nil result
      assert_includes result, "User logged in"
    end

    test "supports multiple denylist patterns" do
      @formatter.denylist = [/health_check/, /ping/, /\.css\z/]

      assert_nil @formatter.call("INFO", @time, nil, "GET /health_check 200")
      assert_nil @formatter.call("INFO", @time, nil, "GET /ping 200")
      assert_nil @formatter.call("INFO", @time, nil, "GET /assets/app.css")
      assert_not_nil @formatter.call("INFO", @time, nil, "GET /users 200")
    end
  end
end
