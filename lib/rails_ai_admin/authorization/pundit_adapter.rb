# frozen_string_literal: true

module RailsAiAdmin
  module Authorization
    # Optional Pundit integration using a separate explicit policy per resource.
    # The policy receives the complete admin Context as its user argument.
    class PunditAdapter < Adapter
      ACTIONS = %i[index show create update destroy restore].freeze
      FIELD_METHODS = { read: :readable_fields, write: :writable_fields,
        search: :searchable_fields, sort: :sortable_fields, filter: :filterable_fields }.freeze

      def initialize
        require "pundit"
        unless Gem::Requirement.new(">= 2.5", "< 3").satisfied_by?(Gem.loaded_specs.fetch("pundit").version)
          raise ConfigurationError, "PunditAdapter requires pundit >= 2.5 and < 3"
        end
      rescue LoadError
        raise ConfigurationError, "Add pundit >= 2.5 and < 3 to the host bundle", cause: nil
      end

      def scope(context:, resource:, relation:)
        klass = policy_class(resource)
        scope = klass && scope_class(klass)
        return relation.none unless scope
        # Pundit's documented explicit Scope constructor/resolve contract avoids
        # guessing a model policy, which would merge resource-alias authority.
        scope.new(context, relation).resolve
      rescue StandardError => error
        policy_error!(resource, error)
      end

      def allowed?(context:, action:, resource:, record: nil)
        return false unless ACTIONS.include?(action.to_sym) || resource.operation_declarations.key?(action.to_sym)
        klass = policy_class(resource)
        target = record || (action.to_sym == :create ? scope(context: context, resource: resource, relation: resource.model_class.all).new : resource.model_class)
        return false unless klass && klass.new(context, target).respond_to?("#{action}?")
        Pundit.authorize(context, target, "#{action}?", policy_class: klass)
        true
      rescue Pundit::NotAuthorizedError
        false
      rescue StandardError => error
        policy_error!(resource, error)
      end

      def fields(context:, resource:, action:, record: nil)
        method = FIELD_METHODS[action.to_sym]
        klass = policy_class(resource)
        return [] unless method && klass
        policy = klass.new(context, record || resource.model_class)
        policy.respond_to?(method) ? policy.public_send(method) : []
      rescue StandardError => error
        policy_error!(resource, error)
      end

      def presentation_fields(context:, resource:, view:, record: nil)
        klass = policy_class(resource)
        return [] unless klass
        policy = klass.new(context, record || resource.model_class)
        return unless policy.respond_to?(:presentation_fields, true)
        raise ConfigurationError, "Presentation policy must be public" unless policy.respond_to?(:presentation_fields)
        policy.presentation_fields(view)
      rescue StandardError => error
        policy_error!(resource, error)
      end

      # Reports whether an explicit policy and its owned/inherited Scope exist.
      # This checks metadata only; it does not attest any authorization decision.
      def configured?(resource)
        klass = policy_class(resource)
        !!(klass && scope_class(klass))
      rescue StandardError => error
        policy_error!(resource, error)
      end

      def operation_fields(context:, resource:, operation:, record: nil)
        klass = policy_class(resource)
        return [] unless klass
        policy = klass.new(context, record || resource.model_class)
        policy.respond_to?(:permitted_operation_fields) ? policy.permitted_operation_fields(operation.to_sym) : []
      rescue StandardError => error
        policy_error!(resource, error)
      end

      def deliver_work?(context:, resource:, operation:, work_kind:, record:)
        klass = policy_class(resource)
        return false unless klass
        policy = klass.new(context, record)
        policy.respond_to?(:deliver_operation_work?) && policy.deliver_operation_work?(operation.to_sym, work_kind.to_s) == true
      rescue StandardError => error
        policy_error!(resource, error)
      end

      def read_operation_receipt?(context:, resource:, operation:, record:)
        klass = policy_class(resource)
        return false unless klass
        policy = klass.new(context, record || resource.model_class)
        policy.respond_to?(:read_operation_receipt?) && policy.read_operation_receipt?(operation.to_sym) == true
      rescue StandardError => error
        policy_error!(resource, error)
      end

      def cancel_operation?(context:, resource:, operation:)
        klass = policy_class(resource)
        return false unless klass
        policy = klass.new(context, resource.model_class)
        policy.respond_to?(:cancel_operation?) && policy.cancel_operation?(operation.to_sym) == true
      rescue StandardError => error
        policy_error!(resource, error)
      end

      def named_scopes(context:, resource:)
        klass = policy_class(resource)
        return [] unless klass
        policy = klass.new(context, resource.model_class)
        policy.respond_to?(:permitted_named_scopes) ? policy.permitted_named_scopes : []
      rescue StandardError => error
        policy_error!(resource, error)
      end

      def select_records?(context:, resource:)
        klass = policy_class(resource)
        return false unless klass
        policy = klass.new(context, resource.model_class)
        policy.respond_to?(:select_records?) && policy.select_records? == true
      rescue StandardError => error
        policy_error!(resource, error)
      end

      def export_records?(context:, resource:)
        klass = policy_class(resource)
        return false unless klass
        policy = klass.new(context, resource.model_class)
        policy.respond_to?(:export_records?) && policy.export_records? == true
      rescue StandardError => error
        policy_error!(resource, error)
      end

      def import_records?(context:, resource:)
        klass = policy_class(resource)
        return false unless klass
        policy = klass.new(context, resource.model_class)
        policy.respond_to?(:import_records?) && policy.import_records? == true
      rescue StandardError => error
        policy_error!(resource, error)
      end

      def view_audit_log?(context:, resource:)
        klass = policy_class(resource)
        return false unless klass
        policy = klass.new(context, resource.model_class)
        policy.respond_to?(:view_audit_log?) && policy.view_audit_log? == true
      rescue StandardError => error
        policy_error!(resource, error)
      end

      def view_history?(context:, resource:, record:)
        klass = policy_class(resource)
        return false unless klass
        policy = klass.new(context, record)
        policy.respond_to?(:view_history?) && policy.view_history? == true
      rescue StandardError => error
        policy_error!(resource, error)
      end

      def assistant?(context:, resource:)
        klass = policy_class(resource)
        return false unless klass
        policy = klass.new(context, resource.model_class)
        policy.respond_to?(:assistant?) && policy.assistant? == true
      rescue StandardError => error
        policy_error!(resource, error)
      end

      private

      def policy_class(resource)
        name = resource.policy
        return unless name
        klass = name.safe_constantize
        raise ConfigurationError, "Policy must resolve to a class" if klass && !klass.is_a?(Class)
        klass
      end

      def scope_class(policy)
        owner = policy.ancestors.take_while { |ancestor| ancestor != Object && ancestor != BasicObject }
          .find { |ancestor| ancestor.is_a?(Class) && ancestor.const_defined?(:Scope, false) }
        owner&.const_get(:Scope, false)
      end

      def policy_error!(resource, error)
        raise ConfigurationError, "Pundit policy failed for #{resource.key} (#{error.class.name})", cause: nil
      end
    end
  end
end
