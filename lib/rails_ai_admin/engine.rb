# frozen_string_literal: true

module RailsAiAdmin
  # Mountable Rails engine. AI integrations remain unloaded during this slice.
  class Engine < ::Rails::Engine
    isolate_namespace RailsAiAdmin

    initializer "rails_ai_admin.assets" do |app|
      if app.config.respond_to?(:assets)
        app.config.assets.paths << root.join("app/assets/builds").to_s
        if app.config.assets.respond_to?(:precompile)
          app.config.assets.precompile += %w[rails_ai_admin.css rails_ai_admin.js]
        end
      end
    end

    config.to_prepare { RailsAiAdmin.prepare! }
    config.after_initialize { RailsAiAdmin.configuration.finalize! }
  end
end
