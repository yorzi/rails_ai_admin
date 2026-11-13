# frozen_string_literal: true

module RailsAiAdmin
  # Snapshot capture/view is deliberately separate from business confirmation.
  class SelectionsController < ApplicationController
    def create
      @resource = RailsAiAdmin.registry.fetch(params[:resource])
      resolve_list_navigation
      # Nothing ticked is an ordinary mistake: return to the same list (RAA-013).
      if Array(params[:target_ids]).compact_blank.empty?
        Authorization::Access.new(@context, @resource).authorize_selection!
        redirect_to list_return_path, status: :see_other, notice: t("rails_ai_admin.selections.empty")
        return
      end
      selection = Selections::Builder.new.capture(context: @context, resource: @resource, target_ids: params[:target_ids])
      redirect_to selection_path(selection_ref: selection.selection_ref, **navigation_params), status: :see_other
    end

    def show
      @selection = Selections::Builder.new.revalidate(context: @context, selection_ref: params[:selection_ref])
      @resource = RailsAiAdmin.registry.fetch(@selection.resource_key)
      resolve_list_navigation
      access = Authorization::Access.new(@context, @resource)
      @operations = RailsAiAdmin.operation_registry.custom(@resource).select do |definition|
        next false unless definition.scope == :collection
        access.authorize!(definition.key)
        definition.fields(access, nil)
        true
      rescue AccessDenied
        false
      end
    end
  end
end
