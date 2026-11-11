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

      # "1abc", "01" and " 1" would otherwise be cast to record 1 (RAA-022).
      # Pages address a record only by the primary key's canonical text; the
      # trusted Runner API still canonicalizes through the scoped lookup.
      def canonical_id?(id)
        return id.positive? if id.is_a?(Integer)
        return false unless id.is_a?(String) && id.valid_encoding? && id.bytesize.between?(1, 150) && !id.match?(/[[:cntrl:]\s]/)
        case resource.model_class.type_for_attribute(resource.model_class.primary_key).type
        when :integer then id.match?(/\A[1-9][0-9]{0,18}\z/)
        when :uuid then id.match?(/\A[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\z/)
        else true
        end
      end

      VIEWS = %i[index show create edit].freeze

      def fields(action, record = nil, operation: nil, view: nil)
        view = write_view(operation, view) if action == :write
        granted = permission_fields(action, record, operation: operation, view: view)
        action == :read && view ? granted.select { |field| field.visible_on?(view) } : granted
      end

      # only: optional field names to compute (for example index columns plus the
      # title); it can narrow but never add to the granted, visible fields.
      def project(record, view: nil, only: nil)
        authorize!(:show, record)
        granted = permission_fields(:read, record, view: view)
        visible = view ? granted.select { |field| field.visible_on?(view) } : granted
        visible = visible.select { |field| only.include?(field.name) } if only
        Fields::Projection.new(self, record, granted).values(fields: visible)
      end

      # Declared named scopes intersected with the current independent grant, in
      # declaration order. This performs no domain query.
      def named_scopes
        declared = resource.scopes
        return [] if declared.empty?
        names = @adapter.respond_to?(:named_scopes) ? @adapter.named_scopes(context: context, resource: resource) : []
        unless names.is_a?(Array) && names.all? { |name| name.is_a?(String) || name.is_a?(Symbol) }
          raise ConfigurationError, "Named scope grants must be an array of names"
        end
        names = names.map(&:to_sym)
        declared.select { |definition| names.include?(definition.name) }
      end

      def authorize_selection!
        authorize!(:index)
        allowed = @adapter.respond_to?(:select_records?) && @adapter.select_records?(context: context, resource: resource) == true
        raise AccessDenied unless allowed
        true
      end

      # The model may see this resource only with the independent assistant
      # grant plus the ordinary index grant; tools still apply every read grant.
      def authorize_assistant!
        authorize!(:index)
        allowed = @adapter.respond_to?(:assistant?) && @adapter.assistant?(context: context, resource: resource) == true
        raise AccessDenied unless allowed
        true
      end

      # Scalar declarations cannot turn arbitrary model methods into read actions.
      # Host overrides of real attribute getters remain trusted application code.
      def read_value(record, field, view: nil)
        unless resource.fields.any? { |candidate| candidate.equal?(field) }
          raise ConfigurationError, "Read fields must belong to the current resource"
        end
        authorize!(:show, record)
        granted = permission_fields(:read, record, view: view)
        raise AccessDenied if view && !field.visible_on?(view)
        Fields::Projection.new(self, record, granted).value(field)
      end

      def read_attribute(record, field)
        raise AccessDenied if field.hidden?
        raise ConfigurationError, "Computed fields do not invoke model methods" if field.virtual?
        name = field.column
        primary_key = record.class.primary_key
        id_alias = name == "id" && primary_key.is_a?(String) && record.has_attribute?(primary_key)
        unless record.has_attribute?(name) || id_alias
          raise ConfigurationError, "Scalar fields must name model attributes"
        end
        value = ActiveRecord::Base.while_preventing_writes { record.public_send(name) }
        # References travel as opaque key text, matching their input contract.
        field.scalar_type == :belongs_to && !value.nil? ? value.to_s : value
      rescue ActiveRecord::ReadOnlyError
        raise ConfigurationError, "Scalar attribute getters must not write", cause: nil
      end

      # Shared title contract for native pages, fixed selections and job entries.
      def record_label(record, values: nil, view: :show)
        fallback = "Record ##{record.id}"
        authorize!(:show, record)
        field = fields(:read, record, view: view).find { |candidate| candidate.name == resource.title }
        return fallback unless field
        return fallback if values && !values.key?(field.name.to_s)
        value = values ? values.fetch(field.name.to_s) : read_value(record, field, view: view)
        field.format(value, time_zone: context.time_zone).truncate(120)
      rescue AccessDenied
        fallback
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

      def authorize_cancel!(operation)
        allowed = @adapter.respond_to?(:cancel_operation?) && @adapter.cancel_operation?(context: context, resource: resource, operation: operation.to_sym) == true
        raise AccessDenied unless allowed
        true
      end

      def authorize_receipt!(operation, record)
        allowed = @adapter.respond_to?(:read_operation_receipt?) && @adapter.read_operation_receipt?(context: context,
          resource: resource, operation: operation.to_sym, record: record) == true
        raise AccessDenied unless allowed
        true
      end
      private

      def write_view(operation, view)
        expected = operation.to_sym == :create ? :create : :edit if operation
        expected ||= :edit
        raise ConfigurationError, "Write presentation must match its lifecycle" if view && view != expected
        expected
      end

      def permission_fields(action, record, operation: nil, view: nil)
        raise ConfigurationError, "Unknown presentation view" if view && !VIEWS.include?(view)
        names = @adapter.fields(context: context, resource: resource, action: action, record: record)
        unless names.is_a?(Array) && names.all? { |name| name.is_a?(String) || name.is_a?(Symbol) }
          raise ConfigurationError, "Policy fields must be an array of names"
        end
        names = names.map(&:to_sym)
        selected = resource.fields.select do |field|
          !field.hidden? && names.include?(field.name) &&
            (action != :write || field.name.to_s != resource.model_class.primary_key) &&
            (action != :write || field.writable?(operation || :update)) &&
            (action != :search || !field.virtual? && field.options[:searchable]) &&
            (action != :sort || !field.virtual? && field.options[:sortable]) &&
            (action != :filter || !field.virtual? && field.filter_operators.any?)
        end
        mask = presentation_mask(record, view) if view
        selected = selected.select { |field| mask.include?(field.name) } if mask
        action == :read ? Fields::DependencyGraph.readable(selected) : selected
      end

      def presentation_mask(record, view)
        return unless @adapter.respond_to?(:presentation_fields, true)
        raise ConfigurationError, "Presentation policy must be public" unless @adapter.respond_to?(:presentation_fields)
        names = ActiveRecord::Base.while_preventing_writes { @adapter.presentation_fields(context: context, resource: resource, view: view, record: record) }
        return if names.nil?
        unless names.is_a?(Array) && names.all? { |name| name.is_a?(String) || name.is_a?(Symbol) }
          raise ConfigurationError, "Presentation policy must return nil or field names"
        end
        names.map(&:to_sym)
      rescue ConfigurationError
        raise
      rescue StandardError
        raise ConfigurationError, "Presentation policy failed", cause: nil
      end
    end
  end
end
