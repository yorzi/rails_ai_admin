# frozen_string_literal: true

module RailsAiAdmin
  # Public base for host-owned Rails routes, controllers and partials. Hosts keep
  # their own route helpers/layout; admin engine links use the mounted proxy.
  class CustomController < ApplicationController
    layout false
    helper_method :admin_routes

    protected

    def admin_context
      raise AccessDenied, "UNAUTHENTICATED" unless @context.is_a?(Context)
      @context
    end

    # Resolving an access object grants nothing: explicitly authorize, use its
    # scoped find/relation and project permitted values before displaying them.
    def admin_access(resource_key)
      Authorization::Access.new(admin_context, RailsAiAdmin.registry.fetch(resource_key))
    end

    def admin_operation_runner = Operations::Runner.new
    def admin_routes = rails_ai_admin
  end
end
