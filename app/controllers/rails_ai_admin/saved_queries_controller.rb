# frozen_string_literal: true

module RailsAiAdmin
  class SavedQueriesController < ApplicationController
    before_action :resolve_resource

    def index
      @reports = Presentation::SavedQueries.renderable(@context, SavedQuery.visible(@context).where(resource_key: @resource.key))
    end

    def create
      raw = params[:definition]
      raise AccessDenied, "INVALID_QUERY" unless raw.is_a?(String) && raw.bytesize <= 8192
      ast = JSON.parse(raw, max_nesting: 12)
      Presentation::SavedQueries.save!(context: @context, resource: @resource, name: params[:name], ast: ast,
        shared: params[:shared] == "1", pinned: params[:pinned] == "1")
      redirect_to saved_queries_path(resource: @resource.key), status: :see_other
    rescue JSON::ParserError
      raise AccessDenied, "INVALID_QUERY"
    end

    def update
      owned.update!(pinned: params[:pinned] == "1")
      redirect_to saved_queries_path(resource: @resource.key), status: :see_other
    end

    def destroy
      owned.destroy!
      redirect_to saved_queries_path(resource: @resource.key), status: :see_other
    end

    private

    def owned
      SavedQuery.find_by(id: params[:id], tenant_ref: @context.tenant_ref, actor_ref: @context.actor_ref, resource_key: @resource.key) || raise(AccessDenied)
    end

    def resolve_resource
      raise AccessDenied unless SavedQuery.table_exists?
      @resource = RailsAiAdmin.registry.fetch(params[:resource])
      Authorization::Access.new(@context, @resource).authorize!(:index)
    end
  end
end
