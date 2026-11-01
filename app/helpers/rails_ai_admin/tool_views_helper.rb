# frozen_string_literal: true

module RailsAiAdmin
  # View helpers for admin-owned review Surfaces. rails_tool_views is touched
  # only when a Surface is actually rendered, never when this file loads.
  module ToolViewsHelper
    # Renders through RailsToolViews.render with fresh authorization. The
    # rails_tool_views view helpers are added to this view instance only.
    def admin_surface(surface, scope:, error: nil)
      extend ::RailsToolViews::SurfacesHelper unless is_a?(::RailsToolViews::SurfacesHelper)
      ::RailsToolViews.render(surface, view_context: self, scope: scope, error: error)
    end

    # Like rails_tool_views_action_form, but posts to the admin endpoint so the
    # host's global resolver never authenticates admin actions.
    def admin_surface_action_form(surface, action, **options, &block)
      fields = rails_tool_views_action_fields(surface, action)
      form_with(url: admin_surface_actions_path(surface_id: surface.id), method: :post, scope: :arguments, namespace: surface.dom_id, **options) do |form|
        safe_join([ fields, (capture(form, &block) if block) ])
      end
    end

    # The current authorized review behind a Surface, or nil.
    def admin_surface_review(props)
      Integrations::ToolViews.review(Integrations::ToolViews.current_context, props)
    end

    def admin_surface_display_values(review, wire)
      Integrations::ToolViews.display_values(review, wire)
    end

    def admin_surface_review_available?(resource, definition)
      RailsAiAdmin.configuration.surfaces && resource.surface_operation?(definition.key)
    end
  end
end
