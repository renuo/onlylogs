begin
  require "importmap-rails"
rescue LoadError
  # importmap-rails is optional
end

module Onlylogs
  class Engine < ::Rails::Engine
    isolate_namespace Onlylogs

    # Load the viewer's code on first use instead of at boot, so apps that only use the
    # loggers don't need the frameworks it builds on (e.g. Action Cable).
    paths.all_paths.select(&:eager_load?).each do |path|
      path.skip_eager_load!
      path.autoload!
    end

    initializer "onlylogs.assets" do |app|
      next unless app.config.respond_to?(:assets)

      %w[images javascript stylesheets builds fonts].each do |subdir|
        path = root.join("app/assets", subdir)
        app.config.assets.paths << path if path.exist?
      end

      app.config.assets.paths << root.join("app/javascript")
      app.config.assets.precompile += %w[onlylogs_manifest]
    end

    if defined?(Importmap)
      initializer "onlylogs.importmap", after: "importmap" do |app|
        Onlylogs.importmap.draw(root.join("config/importmap.rb"))
        if app.config.importmap.sweep_cache && app.config.reloading_enabled?
          Onlylogs.importmap.cache_sweeper(watches: root.join("app/javascript"))

          ActiveSupport.on_load(:action_controller_base) do
            before_action { Onlylogs.importmap.cache_sweeper.execute_if_updated }
          end
        end
      end
    end
  end
end
