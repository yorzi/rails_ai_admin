# frozen_string_literal: true

module RailsAiAdmin
  # Redacts admin query values before Rails logs the initial request URL.
  # The documented mount name is required; its path can be customized/reloaded.
  class RequestLogFilter
    def initialize(app)
      @app = app
    end

    def call(env)
      helpers = Rails.application.routes.url_helpers
      if helpers.respond_to?(:rails_ai_admin_path)
        prefix = helpers.rails_ai_admin_path(script_name: "").delete_suffix("/")
        path = env["PATH_INFO"].to_s
        if path == prefix || path.start_with?("#{prefix}/")
          filter = /\A(?!(?:controller|action|resource|id|format)\z)/
          env["action_dispatch.parameter_filter"] = Array(env["action_dispatch.parameter_filter"]) + [ filter ]
        end
      end
      @app.call(env)
    end
  end
end
