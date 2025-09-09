# frozen_string_literal: true

require "uri"

# kudos to https://github.com/BetterErrors/better_errors for this code!
module Onlylogs
  class FilePathParser
    KNOWN_EDITORS = [
      { symbols: [ :atom ], sniff: /atom/i, url: "atom://core/open/file?filename=%{file}&line=%{line}" },
      { symbols: [ :emacs, :emacsclient ], sniff: /emacs/i, url: "emacs://open?url=file://%{file}&line=%{line}" },
      { symbols: [ :idea ], sniff: /idea/i, url: "idea://open?file=%{file}&line=%{line}" },
      { symbols: [ :macvim, :mvim ], sniff: /vim/i, url: "mvim://open?url=file://%{file_unencoded}&line=%{line}" },
      { symbols: [ :rubymine ], sniff: /mine/i, url: "x-mine://open?file=%{file}&line=%{line}" },
      { symbols: [ :sublime, :subl, :st ], sniff: /subl/i, url: "subl://open?url=file://%{file}&line=%{line}" },
      { symbols: [ :textmate, :txmt, :tm ], sniff: /mate/i, url: "txmt://open?url=file://%{file}&line=%{line}" },
      { symbols: [ :vscode, :code ], sniff: /code/i, url: "vscode://file/%{file}:%{line}" },
      { symbols: [ :vscodium, :codium ], sniff: /codium/i, url: "vscodium://file/%{file}:%{line}" }
    ].freeze

    def self.parse(string)
      return string if string.blank?

      editor = default_editor
      string.gsub(file_path_pattern) do |match|
        file_path = extract_file_path(match)
        line_number = extract_line_number(match)
        url = editor.url(file_path, line_number)
        %(<a href="#{url}" class="file-link">#{match}</a>)
      end
    end

    def self.for_formatting_string(formatting_string)
      new proc { |file, line|
        formatting_string % { file: URI.encode_www_form_component(file), file_unencoded: file, line: line }
      }
    end

    def self.for_proc(url_proc)
      new url_proc
    end

    # Automatically sniffs a default editor preset based on
    # environment variables.
    #
    # @return [FilePathParser]
    def self.default_editor
      editor_from_environment_formatting_string ||
        editor_from_environment_editor ||
        editor_from_symbol(:textmate)
    end

    def self.editor_from_environment_editor
      %w[ONLYLOGS_EDITOR RAILS_EDITOR EDITOR].each do |var|
        editor = editor_from_command(ENV[var]) if ENV[var]
        return editor if editor
      end
      nil
    end

    def self.editor_from_command(editor_command)
      env_preset = KNOWN_EDITORS.find { |preset| editor_command =~ preset[:sniff] }
      for_formatting_string(env_preset[:url]) if env_preset
    end

    def self.editor_from_environment_formatting_string
      return unless ENV["ONLYLOGS_EDITOR_URL"]

      for_formatting_string(ENV["ONLYLOGS_EDITOR_URL"])
    end

    def self.editor_from_symbol(symbol)
      KNOWN_EDITORS.each do |preset|
        return for_formatting_string(preset[:url]) if preset[:symbols].include?(symbol)
      end
    end

    def initialize(url_proc)
      @url_proc = url_proc
    end

    def url(raw_path, line)
      if virtual_path && raw_path.start_with?(virtual_path)
        if host_path
          file = raw_path.sub(%r{\A#{virtual_path}}, host_path)
        else
          file = raw_path.sub(%r{\A#{virtual_path}/}, "")
        end
      else
        file = raw_path
      end

      url_proc.call(file, line)
    end

    def scheme
      url("/fake", 42).sub(/:.*/, ":")
    end

    private

    attr_reader :url_proc

    def virtual_path
      @virtual_path ||= ENV["ONLYLOGS_VIRTUAL_PATH"]
    end

    def host_path
      @host_path ||= ENV["ONLYLOGS_HOST_PATH"]
    end

    # Regex pattern to match file paths with optional line numbers
    # Matches paths like:
    # - /path/to/file.rb:42
    # - ./relative/path.rb:10
    # - /path/to/file.rb (without line number)
    def self.file_path_pattern
      %r{
        (?<![a-zA-Z0-9_/])  # Negative lookbehind - not preceded by word chars or /
        (?:\./)?             # Optional relative path indicator
        (?:/[a-zA-Z0-9_\-\.\s]+)+  # File path with allowed characters
        (?:\.rb|\.js|\.ts|\.tsx|\.jsx|\.py|\.java|\.go|\.rs|\.php|\.html|\.erb|\.haml|\.slim|\.css|\.scss|\.sass|\.less|\.xml|\.json|\.yml|\.yaml|\.md|\.txt|\.log)  # File extensions
        (?::\d+)?            # Optional line number
        (?![a-zA-Z0-9_/])    # Negative lookahead - not followed by word chars or /
      }x
    end

    def self.extract_file_path(match)
      # Remove line number if present
      match.sub(/:\d+$/, "")
    end

    def self.extract_line_number(match)
      # Extract line number or default to 1
      line_match = match.match(/:(\d+)$/)
      line_match ? line_match[1].to_i : 1
    end
  end
end
