# frozen_string_literal: true

module RailsAiAdmin
  module Fields
    class Registry
      Definition = Data.define(:key, :handler_name) do
        def handler_class
          klass = handler_name.constantize
          unless klass.is_a?(Class) && klass < Type && klass.name
            raise ConfigurationError, "Registered field type must inherit RailsAiAdmin::Fields::Type"
          end
          klass
        rescue NameError
          raise ConfigurationError, "Registered field type could not be loaded", cause: nil
        end

        def metadata = handler_class.metadata
      end

      def initialize(types)
        unless types.is_a?(Hash) && types.all? { |key, name| (key.is_a?(String) || key.is_a?(Symbol)) && key.to_s.match?(/\A[a-z][a-z0-9_]{0,39}\z/) && name.is_a?(String) && name.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/) }
          raise ConfigurationError, "field_types must map stable keys to class-name strings"
        end
        @mapping = types.transform_keys(&:to_s).transform_values(&:dup)
        if @mapping.size != types.size || (@mapping.keys & Field::TYPES.map(&:to_s)).any?
          raise ConfigurationError, "Field registrations cannot duplicate or replace built-in types"
        end
        @mapping.each { |key, name| key.freeze; name.freeze }
        @mapping.freeze
        @entries = @mapping.to_h { |key, name| [ key, Definition.new(key, name) ] }.freeze
        freeze
      end

      def matches?(types) = types.is_a?(Hash) && types.transform_keys(&:to_s) == @mapping
      def definitions = @entries.values
      def validate!
        definitions.each(&:metadata)
        self
      end

      def build(name, type:, **options)
        return Field.new(name, type: type, **options) if Field::TYPES.include?(type.to_sym)
        definition = @entries.fetch(type.to_s) { raise ConfigurationError, "Unregistered field type" }
        Field.new(name, type: type, plugin: definition, **options)
      end
    end
  end
end
