# frozen_string_literal: true

module RailsAiAdmin
  # Picker search for reference inputs whose choices exceed the bounded
  # select. :resource is the target resource; the reply holds only what that
  # resource's own index would show this actor for the same term.
  class ReferencesController < ApplicationController
    def search
      target = RailsAiAdmin.registry.fetch(params[:resource])
      term = params[:q]
      raise AccessDenied, "INVALID_QUERY" unless term.nil? || term.is_a?(String)
      results = Fields::Association.search(@context, target, term)
      render json: { results: results.map { |label, id| { id: id, label: label } } }
    end
  end
end
