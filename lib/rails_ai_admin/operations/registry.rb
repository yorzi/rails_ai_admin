# frozen_string_literal: true

module RailsAiAdmin
  module Operations
    # Explicit per-resource definitions. Default CRUD uses the same lookup/boundary.
    class Registry
      CRUD = %w[create update destroy].freeze

      class Definition
        attr_reader :key, :resource, :handler_name

        def initialize(resource, key, handler_name = nil)
          @resource, @key, @handler_name = resource, key.to_s.freeze, handler_name
          handler_class.validate! if custom?
          freeze
        end

        def custom? = !handler_name.nil?
        def handler_class
          return DefaultHandlers::TYPES.fetch(key) unless custom?
          klass = handler_name.constantize
          raise ConfigurationError, "Operation handler must inherit RailsAiAdmin::Operation" unless klass.is_a?(Class) && klass < Operation && !(klass < Work)
          klass
        end
        def description = custom? ? handler_class.description : key.humanize
        def read_only? = false
        def scope = key == "create" && !custom? ? :collection : :member
        def expose_to_ai? = false
        def side_effects? = true
        def approval_policy = custom? || key == "destroy" ? :required : :human_submit
        def idempotency_policy = :intent
        def audit_policy = :required
        def output_type = :record_ref

        def input_json_schema(access, record)
          InputSchema.new(fields(access, record), partial: key == "update" && !custom?).json_schema
        end

        def fields(access, record)
          return [] if key == "destroy" && !custom?
          return access.fields(:write, record, operation: key) unless custom?
          allowed = access.operation_fields(key, record)
          required = handler_class.input.select { |field| field.options[:required] }.map(&:name)
          raise AccessDenied unless (required - allowed.map(&:name)).empty?
          allowed
        end

        def signature
          custom? ? { handler: handler_name, version: handler_class.version, input: handler_class.input.map { |field| [ field.name, field.type, field.options ] },
            models: handler_class.atomic_models, duration: handler_class.max_duration } : { builtin: key, version: 1 }
        end
      end

      def initialize(resources)
        @entries = resources.to_h do |resource|
          definitions = CRUD.to_h { |key| [ key, Definition.new(resource, key) ] }
          resource.operation_declarations.each { |key, handler| definitions[key.to_s] = Definition.new(resource, key, handler) }
          [ resource.key.to_s, definitions.freeze ]
        end.freeze
        freeze
      end

      def fetch(resource, key)
        @entries.fetch(resource.key.to_s, {}).fetch(key.to_s) { raise AccessDenied }
      end

      def custom(resource)
        @entries.fetch(resource.key.to_s, {}).values.select(&:custom?)
      end
    end
  end
end
