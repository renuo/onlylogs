require "importmap-rails"

module Onlylogs
  class Engine < ::Rails::Engine
    isolate_namespace Onlylogs

    initializer "onlylogs.assets" do |app|
      # app.config.assets.paths << root.join("app/assets/stylesheets")
      app.config.assets.paths << root.join("app/javascript")
      app.config.assets.precompile += %w[ onlylogs_manifest ]
    end


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
