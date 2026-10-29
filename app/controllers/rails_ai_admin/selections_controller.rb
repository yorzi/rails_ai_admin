# frozen_string_literal: true

module RailsAiAdmin
  # Snapshot capture/view is deliberately separate from business confirmation.
  class SelectionsController < ApplicationController
    def create
      resource = RailsAiAdmin.registry.fetch(params[:resource])
      selection = Selections::Builder.new.capture(context: @context, resource: resource, target_ids: params[:target_ids])
      redirect_to selection_path(selection_ref: selection.selection_ref), status: :see_other
    end

    def show
      @selection = Selections::Builder.new.revalidate(context: @context, selection_ref: params[:selection_ref])
      @resource = RailsAiAdmin.registry.fetch(@selection.resource_key)
    end
  end
end
