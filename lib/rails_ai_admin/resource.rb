# frozen_string_literal: true

module RailsAiAdmin
  # Describes explicit exposure of a host model. No attributes are auto-published.
  class Resource
    class << self
      def inherited(child)
        super
        child.instance_variable_set(:@fields, {})
        child.instance_variable_set(:@disabled_actions, [])
        child.instance_variable_set(:@operations, {})
        child.instance_variable_set(:@operation_scopes, {})
      end

      def model(name = nil)
        @model_name = name if name
        @model_name
      end

      def key(value = nil)
        @key = value.to_sym if value
        @key
      end

      def label(value = nil)
        @label = value if value
        @label || key.to_s.humanize
      end

      def title(value = nil)
        @title = value.to_sym if value
        @title
      end

      # Names an explicit optional policy for this resource, independent of aliases.
      def policy(name = nil)
        @policy_name = name if name
        @policy_name
      end

      def readonly(value = true)
        @readonly = value
      end

      def readonly? = @readonly == true

      def disable(*actions)
        @disabled_actions.concat(actions.map(&:to_sym))
      end

      def action_enabled?(action)
        action = action.to_sym
        known = %i[index show create update destroy].include?(action) || @operations.key?(action)
        known && !@disabled_actions.include?(action) && !(readonly? && (%i[create update destroy].include?(action) || @operations.key?(action)))
      end

      def operation(key, handler:, scope: :member, confirmation: :required)
        unless key.to_s.match?(/\A[a-z][a-z0-9_]*\z/) && !%w[index show create update destroy new edit].include?(key.to_s)
          raise ConfigurationError, "Custom operation needs a distinct stable key"
        end
        unless handler.is_a?(String) && handler.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/) && %i[member collection].include?(scope) && confirmation == :required
          raise ConfigurationError, "Use a handler class-name string, member/collection scope and required confirmation"
        end
        raise ConfigurationError, "Duplicate operation #{key}" if @operations.key?(key.to_sym)
        @operations[key.to_sym] = handler.freeze
        @operation_scopes[key.to_sym] = scope
      end

      def operation_declarations = @operations
      def operation_scopes = @operation_scopes

      def fields(&block)
        FieldBuilder.new(@fields).instance_eval(&block) if block
        @fields.values
      end

      def model_class
        raise ConfigurationError, "model must be a constant name string" unless model.is_a?(String)
        klass = model.constantize
        raise ConfigurationError, "model must inherit ActiveRecord::Base" unless klass < ActiveRecord::Base
        klass
      end

      def validate!
        raise ConfigurationError, "model must be a constant name string" unless model.is_a?(String)
        if policy && (!policy.is_a?(String) || !policy.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/))
          raise ConfigurationError, "policy must be a constant name string"
        end
        raise ConfigurationError, "A resource must declare fields and a title" if fields.empty? || !title || !@fields.key?(title)
        raise ConfigurationError, "A resource cannot declare lock_version as a field" if @fields.key?(:lock_version)
        Fields::DependencyGraph.validate!(fields)
        @policy_name&.freeze
        @fields.freeze
        @disabled_actions.freeze
        @operations.freeze
        @operation_scopes.freeze
        self
      end
    end

    # Collects field declarations without consulting the database at boot.
    class FieldBuilder
      def initialize(fields)
        @fields = fields
      end

      def field(name, type:, **options)
        raise ConfigurationError, "Duplicate field #{name}" if @fields.key?(name.to_sym)
        @fields[name.to_sym] = RailsAiAdmin.field_registry.build(name, type: type, **options)
      end

      def virtual(name, type:, depends_on:, compute:, **options)
        field(name, type: type, compute: compute, depends_on: depends_on, **options)
      end

      def readonly(name, type: :text, **options)
        field(name, type: type, **options.merge(readonly: true))
      end

      Field::TYPES.each do |type|
        define_method(type) { |name, **options| field(name, type: type, **options) }
      end
    end
  end
end
