# frozen_string_literal: true

module RailsAiAdmin
  module Authorization
    # Intersects host decisions with declared exposure on every use.
    class Access
      attr_reader :context, :resource

      def initialize(context, resource)
        raise AccessDenied, "UNAUTHENTICATED" unless context.is_a?(Context)
        @context, @resource = context, resource
        @adapter = RailsAiAdmin.configuration.authorization_adapter.constantize.new
      end

      def authorize!(action, record = nil)
        raise AccessDenied unless resource.action_enabled?(action) && @adapter.allowed?(context: context, action: action.to_sym, resource: resource, record: record) == true
        true
      end

      def relation
        relation = @adapter.scope(context: context, resource: resource, relation: resource.model_class.all)
        unless relation.is_a?(ActiveRecord::Relation) && relation.klass == resource.model_class
          raise ConfigurationError, "Policy scope must return the resource's ActiveRecord relation"
        end
        if relation.limit_value || relation.offset_value || relation.select_values.any? || relation.group_values.any? || !relation.having_clause.empty? || !relation.from_clause.empty?
          raise ConfigurationError, "Policy scope must be a complete filter relation without limit, offset, select, group, having or from"
        end
        relation
      end

      def find!(id, action: :show, lock: false)
        scoped = relation
        scoped = scoped.lock if lock
        record = scoped.find(id)
        authorize!(action, record)
        record
      rescue ActiveRecord::RecordNotFound
        raise AccessDenied
      end

      def fields(action, record = nil, operation: nil)
        names = @adapter.fields(context: context, resource: resource, action: action, record: record)
        raise ConfigurationError, "Policy fields must be an array" unless names.is_a?(Array)
        names = names.map(&:to_sym)
        resource.fields.select do |field|
          names.include?(field.name) &&
            (action != :write || field.name.to_s != resource.model_class.primary_key) &&
            (action != :write || field.writable?(operation || :update)) &&
            (action != :search || field.options[:searchable]) &&
            (action != :sort || field.options[:sortable])
        end
      end

      def project(record)
        authorize!(:show, record)
        fields(:read, record).to_h { |field| [ field.name.to_s, read_value(record, field) ] }
      end

      def authorize_selection!
        authorize!(:index)
        allowed = @adapter.respond_to?(:select_records?) && @adapter.select_records?(context: context, resource: resource) == true
        raise AccessDenied unless allowed
        true
      end

      # Scalar declarations cannot turn arbitrary model methods into read actions.
      # Host overrides of real attribute getters remain trusted application code.
      def read_value(record, field)
        name = field.name.to_s
        primary_key = record.class.primary_key
        id_alias = name == "id" && primary_key.is_a?(String) && record.has_attribute?(primary_key)
        unless record.has_attribute?(name) || id_alias
          raise ConfigurationError, "Scalar fields must name model attributes"
        end
        record.public_send(name)
      end

      def operation_fields(operation, record = nil)
        definition = RailsAiAdmin.operation_registry.fetch(resource, operation)
        return [] unless definition.custom?
        names = @adapter.respond_to?(:operation_fields) ? @adapter.operation_fields(context: context, resource: resource, operation: operation.to_sym, record: record) : []
        raise ConfigurationError, "Operation fields must be an array" unless names.is_a?(Array)
        names = names.map(&:to_sym)
        definition.handler_class.input.select { |field| names.include?(field.name) }
      end

      def authorize_delivery!(operation, work_kind, record)
        allowed = @adapter.respond_to?(:deliver_work?) && @adapter.deliver_work?(context: context, resource: resource,
          operation: operation.to_sym, work_kind: work_kind, record: record) == true
        raise AccessDenied unless allowed
        true
      end

      def authorize_receipt!(operation, record)
        allowed = @adapter.respond_to?(:read_operation_receipt?) && @adapter.read_operation_receipt?(context: context,
          resource: resource, operation: operation.to_sym, record: record) == true
        raise AccessDenied unless allowed
        true
      end
    end
  end
end
