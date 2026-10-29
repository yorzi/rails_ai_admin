# frozen_string_literal: true

require "rails_ai_admin"

module RailsAiAdmin
  # Framework-neutral host assertions. Raises AssertionError without Minitest/RSpec.
  module TestKit
    class AssertionError < StandardError; end
    FIELD_ACTIONS = %i[read write search sort].freeze

    # Supply a host controller/request representing an anonymous session. This
    # checks the adapter contract; also test the real anonymous HTTP entry point.
    def self.assert_unauthenticated(adapter:, controller:)
      raise AssertionError, "Anonymous context must resolve to nil" unless adapter.resolve(controller).nil?
      true
    end

    # Snapshots independent field grants, intersected with DSL flags. No record
    # values are returned. Action permission and SQL membership are separate.
    def self.field_grants(context:, resource:, record: nil, operation: :update)
      raise ArgumentError, "Use create or update field grants" unless %w[create update].include?(operation.to_s)
      access = Authorization::Access.new(context, resource)
      FIELD_ACTIONS.to_h do |action|
        [ action.to_s, access.fields(action, record, operation: operation).map { |field| field.name.to_s }.sort ]
      end
    end

    def self.assert_field_grants(context:, resource:, expected:, record: nil, operation: :update)
      unless expected.is_a?(Hash) && expected.keys.map(&:to_s).sort == FIELD_ACTIONS.map(&:to_s).sort && expected.values.all? { |names| names.is_a?(Array) }
        raise ArgumentError, "Expected read/write/search/sort arrays"
      end
      normalized = expected.to_h { |action, names| [ action.to_s, names.map(&:to_s).sort ] }
      actual = field_grants(context: context, resource: resource, record: record, operation: operation)
      differences = FIELD_ACTIONS.map(&:to_s).select { |action| actual.fetch(action) != normalized.fetch(action) }
      raise AssertionError, "Field grants differ for #{resource.key}: #{differences.join(', ')}" if differences.any?
      true
    end

    def self.assert_access(context:, resource:, action:, allowed:, record: nil)
      access = Authorization::Access.new(context, resource)
      actual = begin
        access.authorize!(action, record)
        true
      rescue AccessDenied
        false
      end
      raise AssertionError, "Expected #{resource.key}.#{action} allowed=#{allowed}, got #{actual}" unless actual == allowed
      true
    end

    def self.assert_isolated(context:, resource:, foreign_id:)
      access = Authorization::Access.new(context, resource)
      raise AssertionError, "Policy scope includes another tenant's record" if access.relation.where(resource.model_class.primary_key => foreign_id).exists?
      true
    end

    def self.assert_hidden(context:, resource:, field:, actions: [ :read, :write, :search, :sort ], record: nil)
      access = Authorization::Access.new(context, resource)
      actions.each do |action|
        if access.fields(action, record).any? { |entry| entry.name == field.to_sym }
          raise AssertionError, "#{field} is exposed through #{action}"
        end
      end
      true
    end
  end
end
