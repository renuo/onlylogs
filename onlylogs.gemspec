require_relative "lib/onlylogs/version"

Gem::Specification.new do |spec|
  spec.name        = "onlylogs"
  spec.version     = Onlylogs::VERSION
  spec.authors     = [ "Alessandro Rodi" ]
  spec.email       = [ "alessandro.rodi@renuo.ch" ]
  spec.homepage    = "https://onlylogs.io"
  spec.summary     = "A Rails engine to view, stream, grep log files in real-time."
  spec.description = "This gem includes all the tools needed to view and stream you log files directly on a web interface."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/renuo/onlylogs"
  spec.metadata["changelog_uri"] = "https://github.com/renuo/onlylogs/CHANGELOG.md"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md", "bin/onlylogs_sidecar"]
  end
  spec.bindir        = "bin"
  spec.executables   = ["onlylogs_sidecar"]

  spec.add_dependency "rails", "~> 8.0"
end
