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
      @actor_labels = actor_labels(@page.entries.map(&:actor_ref).uniq | [ @filters["actor"] ].compact)
    end
  end
end
