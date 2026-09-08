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

    test "formats non-string messages instead of raising" do
      assert_includes @formatter.call("INFO", @time, nil, nil), "nil"
      assert_includes @formatter.call("INFO", @time, nil, 42), "42"
      assert_includes @formatter.call("WARN", @time, nil, :symbol), ":symbol"
      assert_includes @formatter.call("INFO", @time, nil, {user: 1}), "{user: 1}"
    end

    test "formats exceptions with their message, class and backtrace" do
      error = RuntimeError.new("boom")
      error.set_backtrace(["app/models/user.rb:1:in `save'"])

      result = @formatter.call("ERROR", @time, nil, error)
      assert_includes result, "boom (RuntimeError)"
      assert_includes result, "app/models/user.rb:1"
    end

    test "applies filters to the stringified message" do
      @formatter.denylist = [/secret/]

      assert_nil @formatter.call("ERROR", @time, nil, RuntimeError.new("secret leaked"))
      assert_nil @formatter.call("INFO", @time, nil, :"Onlylogs::LogsChannel")
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
