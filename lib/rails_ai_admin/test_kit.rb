# frozen_string_literal: true

require "rails_ai_admin"

module RailsAiAdmin
  # Framework-neutral host assertions. Raises AssertionError without Minitest/RSpec.
  module TestKit
    class AssertionError < StandardError; end

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
