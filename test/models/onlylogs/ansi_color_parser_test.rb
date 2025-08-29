require "test_helper"

class Onlylogs::AnsiColorParserTest < ActiveSupport::TestCase
  test "converts red color to log-red class" do
    input = "\u001b[31mRed text\u001b[0m"
    result = Onlylogs::AnsiColorParser.parse(input)
    assert_equal '<span class="log-red">Red text</span>', result
  end

  test "converts cyan color to log-cyan class" do
    input = "\u001b[36mCyan text\u001b[0m"
    result = Onlylogs::AnsiColorParser.parse(input)
    assert_equal '<span class="log-cyan">Cyan text</span>', result
  end

  test "converts blue color to log-blue class" do
    input = "\u001b[34mBlue text\u001b[0m"
    result = Onlylogs::AnsiColorParser.parse(input)
    assert_equal '<span class="log-blue">Blue text</span>', result
  end

  test "converts green color to log-green class" do
    input = "\u001b[32mGreen text\u001b[0m"
    result = Onlylogs::AnsiColorParser.parse(input)
    assert_equal '<span class="log-green">Green text</span>', result
  end

  test "converts yellow color to log-yellow class" do
    input = "\u001b[33mYellow text\u001b[0m"
    result = Onlylogs::AnsiColorParser.parse(input)
    assert_equal '<span class="log-yellow">Yellow text</span>', result
  end

  test "converts bold to fw-bold class" do
    input = "\u001b[1mBold text\u001b[0m"
    result = Onlylogs::AnsiColorParser.parse(input)
    assert_equal '<span class="fw-bold">Bold text</span>', result
  end

  test "applies both bold and cyan classes" do
    input = "\u001b[1m\u001b[36mBold cyan text\u001b[0m"
    result = Onlylogs::AnsiColorParser.parse(input)
    assert_equal '<span class="fw-bold"><span class="log-cyan">Bold cyan text</span></span>', result
  end

  test "correctly parses complex log line" do
    input = "\u001b[1m\u001b[36mActiveRecord::SchemaMigration Load (1.0ms)\u001b[0m  \u001b[1m\u001b[34mSELECT \"schema_migrations\".\"version\" FROM \"schema_migrations\" ORDER BY \"schema_migrations\".\"version\" ASC\u001b[0m"
    result = Onlylogs::AnsiColorParser.parse(input)
    expected = '<span class="fw-bold"><span class="log-cyan">ActiveRecord::SchemaMigration Load (1.0ms)</span></span>  <span class="fw-bold"><span class="log-blue">SELECT "schema_migrations"."version" FROM "schema_migrations" ORDER BY "schema_migrations"."version" ASC</span></span>'
    assert_equal expected, result
  end

  test "ignores unknown codes" do
    input = "\u001b[99mUnknown color\u001b[0m"
    result = Onlylogs::AnsiColorParser.parse(input)
    assert_equal "Unknown color", result
  end

  test "closes any remaining open spans" do
    input = "\u001b[31mRed text without reset"
    result = Onlylogs::AnsiColorParser.parse(input)
    assert_equal '<span class="log-red">Red text without reset</span>', result
  end

  test "handles multiple color changes correctly" do
    input = "\u001b[31mRed\u001b[0m\u001b[32mGreen\u001b[0m\u001b[34mBlue\u001b[0m"
    result = Onlylogs::AnsiColorParser.parse(input)
    expected = '<span class="log-red">Red</span><span class="log-green">Green</span><span class="log-blue">Blue</span>'
    assert_equal expected, result
  end

  test "returns empty string with empty input" do
    result = Onlylogs::AnsiColorParser.parse("")
    assert_equal "", result
  end

  test "returns nil with nil input" do
    result = Onlylogs::AnsiColorParser.parse(nil)
    assert_nil result
  end

  test "returns the original string unchanged when no ANSI codes" do
    input = "Plain text without any ANSI codes"
    result = Onlylogs::AnsiColorParser.parse(input)
    assert_equal "Plain text without any ANSI codes", result
  end

  test "preserves non-colored text with mixed content" do
    input = "Start \u001b[31mred\u001b[0m middle \u001b[32mgreen\u001b[0m end"
    result = Onlylogs::AnsiColorParser.parse(input)
    expected = 'Start <span class="log-red">red</span> middle <span class="log-green">green</span> end'
    assert_equal expected, result
  end
end
