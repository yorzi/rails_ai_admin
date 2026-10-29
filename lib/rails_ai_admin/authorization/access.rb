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
            (action != :write || field.writable?(operation || :update)) &&
            (action != :search || field.options[:searchable]) &&
            (action != :sort || field.options[:sortable])
        end
      end

      def project(record)
        fields(:read, record).to_h { |field| [ field.name.to_s, record.public_send(field.name) ] }
      end
    end
  end
end
