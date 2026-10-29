# frozen_string_literal: true

module RailsAiAdmin
  # Describes explicit exposure of a host model. No attributes are auto-published.
  class Resource
    class << self
      def inherited(child)
        super
        child.instance_variable_set(:@fields, {})
        child.instance_variable_set(:@disabled_actions, [])
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

      def readonly(value = true)
        @readonly = value
      end

      def readonly? = @readonly == true

      def disable(*actions)
        @disabled_actions.concat(actions.map(&:to_sym))
      end

      def action_enabled?(action)
        !@disabled_actions.include?(action.to_sym) && !(readonly? && %i[create update destroy].include?(action.to_sym))
      end

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
        raise ConfigurationError, "A resource must declare fields and a title" if fields.empty? || !title || !@fields.key?(title)
        raise ConfigurationError, "A resource cannot declare lock_version as a field" if @fields.key?(:lock_version)
        @fields.freeze
        @disabled_actions.freeze
        self
      end
    end

    # Collects field declarations without consulting the database at boot.
    class FieldBuilder
      def initialize(fields)
        @fields = fields
      end

      Field::TYPES.each do |type|
        define_method(type) do |name, **options|
          raise ConfigurationError, "Duplicate field #{name}" if @fields.key?(name.to_sym)
          @fields[name.to_sym] = Field.new(name, type: type, **options)
        end
      end
    end
  end
end
