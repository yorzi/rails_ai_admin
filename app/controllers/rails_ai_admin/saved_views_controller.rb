# frozen_string_literal: true

module RailsAiAdmin
  # Saves and removes a person's named list settings. Opening a view is an
  # ordinary list link; nothing here reads or changes records.
  class SavedViewsController < ApplicationController
    before_action :resolve_view_resource

    def create
      view = Navigation::SavedViews.new(@access).save(params[:name], navigation_state)
      redirect_to resources_path(resource: @resource.key, **view.state.symbolize_keys), status: :see_other,
        notice: t("rails_ai_admin.saved_views.saved", name: view.name)
    rescue Navigation::SavedViews::Rejected => error
      redirect_to list_return_path, status: :see_other, notice: t("rails_ai_admin.saved_views.rejected.#{error.reason}",
        count: Navigation::SavedViews::MAX_PER_RESOURCE, max: Navigation::SavedViews::MAX_NAME)
    end

    def destroy
      Navigation::SavedViews.new(@access).delete(params[:id])
      redirect_to list_return_path, status: :see_other, notice: t("rails_ai_admin.saved_views.deleted")
    end

    private

    def resolve_view_resource
      raise AccessDenied unless Navigation::SavedViews.available?
      @resource = RailsAiAdmin.registry.fetch(params[:resource])
      @access = Authorization::Access.new(@context, @resource)
      @access.authorize!(:index)
      resolve_list_navigation
    end
  end
end
