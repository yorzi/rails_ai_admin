# frozen_string_literal: true

module RailsAiAdmin
  module Queries
    # A declared list tab. It can only narrow the current authorized relation:
    # its body builds a separate candidate relation whose primary keys are then
    # intersected with the policy scope, so `unscoped`, `or` or a replaced
    # condition inside the body cannot widen the result.
    class NamedScope
      NAME = /\A[a-z][a-z0-9_]{0,39}\z/
      # List state for "no list tab": the whole policy relation even when a
      # default scope exists (RAA-006). It cannot collide with NAME, and it
      # narrows nothing the policy relation does not already allow.
      NONE = "_none"
      MAX_SCOPES = 20
      attr_reader :name, :label, :body

      def initialize(name, body = nil, label: nil, default: false)
        unless (name.is_a?(String) || name.is_a?(Symbol)) && name.to_s.match?(NAME)
          raise ConfigurationError, "Named scope needs a lowercase identifier of at most 40 characters"
        end
        unless body.nil? || body.is_a?(Proc) && body.lambda? && body.arity.zero?
          raise ConfigurationError, "Named scope body must be a zero-argument lambda"
        end
        raise ConfigurationError, "Named scope default must be boolean" unless [ true, false ].include?(default)
        @name = name.to_sym
        @label = Navigation::Settings.caption(label) || Navigation::Settings.caption(@name.to_s.humanize)
        @body = body
        @default = default
        freeze
      end

      def default? = @default

      # Returns the policy relation narrowed to this scope. Trusted host Ruby
      # still runs here; writes are prevented and failures stay generic.
      def apply(relation)
        return relation if body.nil?
        model = relation.klass
        primary_key = model.primary_key
        raise ConfigurationError, "Named scopes require a single-column primary key" unless primary_key.is_a?(String)
        candidate = build(model)
        unless candidate.is_a?(ActiveRecord::Relation) && candidate.klass == model
          raise ConfigurationError, "Named scope #{name} must return the resource's ActiveRecord relation"
        end
        if candidate.limit_value || candidate.offset_value || candidate.select_values.any? || candidate.group_values.any? ||
            !candidate.having_clause.empty? || !candidate.from_clause.empty? ||
            candidate.includes_values.any? || candidate.eager_load_values.any? || candidate.preload_values.any?
          raise ConfigurationError, "Named scope #{name} must be a filter relation without limit, offset, select, group, having, from or eager loading"
        end
        relation.where(primary_key => candidate.unscope(:order).select(model.arel_table[primary_key]))
      end

      private

      def build(model)
        ActiveRecord::Base.while_preventing_writes { model.all.instance_exec(&body) }
      rescue ConfigurationError
        raise
      rescue StandardError
        raise ConfigurationError, "Named scope #{name} failed", cause: nil
      end
    end
  end
end
