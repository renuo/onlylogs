require "test_helper"

class Onlylogs::FilePathParserTest < ActiveSupport::TestCase
  def setup
    @original_editor = ENV["EDITOR"]
    @original_onlylogs_editor = ENV["ONLYLOGS_EDITOR"]
    @original_onlylogs_editor_url = ENV["ONLYLOGS_EDITOR_URL"]
    @original_virtual_path = ENV["ONLYLOGS_VIRTUAL_PATH"]
    @original_host_path = ENV["ONLYLOGS_HOST_PATH"]
  end

  def teardown
    ENV["EDITOR"] = @original_editor
    ENV["ONLYLOGS_EDITOR"] = @original_onlylogs_editor
    ENV["ONLYLOGS_EDITOR_URL"] = @original_onlylogs_editor_url
    ENV["ONLYLOGS_VIRTUAL_PATH"] = @original_virtual_path
    ENV["ONLYLOGS_HOST_PATH"] = @original_host_path
  end

  test "converts file path with line number to clickable link" do
    ENV["EDITOR"] = "code"
    input = "Error in /path/to/file.rb:42: syntax error"
    result = Onlylogs::FilePathParser.parse(input)
    expected = 'Error in <a href="vscode://file/%2Fpath%2Fto%2Ffile.rb:42" class="file-link">/path/to/file.rb:42</a>: syntax error'
    assert_equal expected, result
  end

  test "converts multiple file paths in same line" do
    ENV["EDITOR"] = "code"
    input = "Error in /path/to/file.rb:42 and /another/file.rb:10"
    result = Onlylogs::FilePathParser.parse(input)
    expected = 'Error in <a href="vscode://file/%2Fpath%2Fto%2Ffile.rb:42" class="file-link">/path/to/file.rb:42</a> and <a href="vscode://file/%2Fanother%2Ffile.rb:10" class="file-link">/another/file.rb:10</a>'
    assert_equal expected, result
  end

  test "handles file paths without line numbers" do
    ENV["EDITOR"] = "code"
    input = "Loading file /path/to/file.rb"
    result = Onlylogs::FilePathParser.parse(input)
    expected = 'Loading file <a href="vscode://file/%2Fpath%2Fto%2Ffile.rb:1" class="file-link">/path/to/file.rb</a>'
    assert_equal expected, result
  end

  test "supports VS Code editor" do
    ENV["EDITOR"] = "code"
    input = "Error in /path/to/file.rb:42"
    result = Onlylogs::FilePathParser.parse(input)
    assert_includes result, 'href="vscode://file/%2Fpath%2Fto%2Ffile.rb:42"'
  end

  test "supports Sublime Text editor" do
    ENV["EDITOR"] = "subl"
    input = "Error in /path/to/file.rb:42"
    result = Onlylogs::FilePathParser.parse(input)
    assert_includes result, 'href="subl://open?url=file://%2Fpath%2Fto%2Ffile.rb&line=42"'
  end

  test "supports Atom editor" do
    ENV["EDITOR"] = "atom"
    input = "Error in /path/to/file.rb:42"
    result = Onlylogs::FilePathParser.parse(input)
    assert_includes result, 'href="atom://core/open/file?filename=%2Fpath%2Fto%2Ffile.rb&line=42"'
  end

  test "supports TextMate editor" do
    ENV["EDITOR"] = "mate"
    input = "Error in /path/to/file.rb:42"
    result = Onlylogs::FilePathParser.parse(input)
    assert_includes result, 'href="txmt://open?url=file://%2Fpath%2Fto%2Ffile.rb&line=42"'
  end

  test "supports Vim editor" do
    ENV["EDITOR"] = "vim"
    input = "Error in /path/to/file.rb:42"
    result = Onlylogs::FilePathParser.parse(input)
    assert_includes result, 'href="mvim://open?url=file:///path/to/file.rb&line=42"'
  end

  test "supports RubyMine editor" do
    ENV["EDITOR"] = "mine"
    input = "Error in /path/to/file.rb:42"
    result = Onlylogs::FilePathParser.parse(input)
    assert_includes result, 'href="x-mine://open?file=%2Fpath%2Fto%2Ffile.rb&line=42"'
  end

  test "supports IntelliJ IDEA editor" do
    ENV["EDITOR"] = "idea"
    input = "Error in /path/to/file.rb:42"
    result = Onlylogs::FilePathParser.parse(input)
    assert_includes result, 'href="idea://open?file=%2Fpath%2Fto%2Ffile.rb&line=42"'
  end

  test "supports Emacs editor" do
    ENV["EDITOR"] = "emacs"
    input = "Error in /path/to/file.rb:42"
    result = Onlylogs::FilePathParser.parse(input)
    assert_includes result, 'href="emacs://open?url=file://%2Fpath%2Fto%2Ffile.rb&line=42"'
  end

  test "supports VSCodium editor" do
    ENV["EDITOR"] = "codium"
    input = "Error in /path/to/file.rb:42"
    result = Onlylogs::FilePathParser.parse(input)
    assert_includes result, 'href="vscodium://file/%2Fpath%2Fto%2Ffile.rb:42"'
  end

  test "uses ONLYLOGS_EDITOR when set" do
    ENV["ONLYLOGS_EDITOR"] = "code"
    ENV["EDITOR"] = "vim"
    input = "Error in /path/to/file.rb:42"
    result = Onlylogs::FilePathParser.parse(input)
    assert_includes result, 'href="vscode://file/%2Fpath%2Fto%2Ffile.rb:42"'
  end

  test "uses ONLYLOGS_EDITOR_URL when set" do
    ENV["ONLYLOGS_EDITOR_URL"] = "custom://open?file=%{file}&line=%{line}"
    input = "Error in /path/to/file.rb:42"
    result = Onlylogs::FilePathParser.parse(input)
    assert_includes result, 'href="custom://open?file=%2Fpath%2Fto%2Ffile.rb&line=42"'
  end

  test "defaults to TextMate when no editor is set" do
    ENV["EDITOR"] = nil
    ENV["ONLYLOGS_EDITOR"] = nil
    ENV["ONLYLOGS_EDITOR_URL"] = nil
    input = "Error in /path/to/file.rb:42"
    result = Onlylogs::FilePathParser.parse(input)
    assert_includes result, 'href="txmt://open?url=file://%2Fpath%2Fto%2Ffile.rb&line=42"'
  end

  test "handles virtual path mapping" do
    ENV["EDITOR"] = "code"
    ENV["ONLYLOGS_VIRTUAL_PATH"] = "/app"
    ENV["ONLYLOGS_HOST_PATH"] = "/Users/user/project"
    input = "Error in /app/models/user.rb:42"
    result = Onlylogs::FilePathParser.parse(input)
    assert_includes result, 'href="vscode://file/%2FUsers%2Fuser%2Fproject%2Fmodels%2Fuser.rb:42"'
  end

  test "handles virtual path without host path" do
    ENV["EDITOR"] = "code"
    ENV["ONLYLOGS_VIRTUAL_PATH"] = "/app"
    ENV["ONLYLOGS_HOST_PATH"] = nil
    input = "Error in /app/models/user.rb:42"
    result = Onlylogs::FilePathParser.parse(input)
    assert_includes result, 'href="vscode://file/models%2Fuser.rb:42"'
  end

  test "returns original string when no file paths found" do
    ENV["EDITOR"] = "code"
    input = "This is just a regular log message"
    result = Onlylogs::FilePathParser.parse(input)
    assert_equal input, result
  end

  test "handles empty string" do
    ENV["EDITOR"] = "code"
    result = Onlylogs::FilePathParser.parse("")
    assert_equal "", result
  end

  test "handles nil input" do
    ENV["EDITOR"] = "code"
    result = Onlylogs::FilePathParser.parse(nil)
    assert_nil result
  end

  test "handles file paths with special characters" do
    ENV["EDITOR"] = "code"
    input = "Error in /path/with spaces/file.rb:42"
    result = Onlylogs::FilePathParser.parse(input)
    assert_includes result, 'href="vscode://file/%2Fpath%2Fwith+spaces%2Ffile.rb:42"'
  end

  test "handles relative file paths" do
    ENV["EDITOR"] = "code"
    input = "Error in ./app/models/user.rb:42"
    result = Onlylogs::FilePathParser.parse(input)
    assert_includes result, 'href="vscode://file/%2Fapp%2Fmodels%2Fuser.rb:42"'
  end

  test "handles file paths with query parameters" do
    ENV["EDITOR"] = "code"
    input = "Error in /path/to/file.rb:42:10"
    result = Onlylogs::FilePathParser.parse(input)
    assert_includes result, 'href="vscode://file/%2Fpath%2Fto%2Ffile.rb:42"'
  end

  test "preserves other content around file paths" do
    ENV["EDITOR"] = "code"
    input = "Started GET \"/users\" for 127.0.0.1 at 2023-01-01 12:00:00 +0000\nProcessing by UsersController#index as HTML\n  Rendering /app/views/users/index.html.erb"
    result = Onlylogs::FilePathParser.parse(input)
    assert_includes result, 'href="vscode://file/%2Fapp%2Fviews%2Fusers%2Findex.html.erb:1"'
    assert_includes result, 'Started GET "/users"'
    assert_includes result, "Processing by UsersController#index"
  end
end
