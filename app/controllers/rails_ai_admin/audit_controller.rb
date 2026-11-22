# frozen_string_literal: true

module RailsAiAdmin
  # Recent changes across records for the resources the actor may audit.
  class AuditController < ApplicationController
    FILTERS = %w[resource operation status actor before].freeze

    def index
      @log = Presentation::AuditLog.new(@context)
      @filters = FILTERS.to_h { |key| [ key, params[key] ] }.compact_blank
      raise AccessDenied, "INVALID_QUERY" unless @filters.values.all? { |value| value.is_a?(String) }
      @page = @log.page(**@filters.transform_keys(&:to_sym))
      refs = @page.entries.map(&:actor_ref).uniq
      actor = @filters["actor"]
      refs << actor if actor && !refs.include?(actor) && @log.actor_present?(actor)
      @actor_labels = actor_labels(refs)
      @actor_labels[actor] ||= default_actor_label(actor) if actor
    end
  end
end
