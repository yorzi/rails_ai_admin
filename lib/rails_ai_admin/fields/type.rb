# frozen_string_literal: true

module RailsAiAdmin
  module Fields
    # Pure refinements of an explicitly granted core scalar. Never an authority
    # or record lookup API. Each invocation gets a new, stateless instance.
    class Type
      extend HookSignatures
      class << self
        def scalar(value = nil)
          @scalar = value.to_sym if value
          @scalar
        end

        def version(value = nil)
          @version = value if value
          @version || "1"
        end

        %i[form_partial index_partial show_partial].each do |method|
          define_method(method) do |value = nil|
            instance_variable_set("@#{method}", value) if value
            instance_variable_get("@#{method}")
          end
        end

        def metadata
          unless scalar && Field::TYPES.include?(scalar) && scalar != :belongs_to && version.is_a?(String) && version.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}\z/)
            raise ConfigurationError, "Field type needs a built-in scalar and bounded version"
          end
          partials = %i[form_partial index_partial show_partial].to_h { |key| [ key, public_send(key) ] }
          unless partials.values.all? { |path| path.nil? || path.is_a?(String) && path.length <= 200 && path.match?(/\A[a-z][a-z0-9_]*(?:\/[a-z][a-z0-9_]*)*\z/) }
            raise ConfigurationError, "Field partials must be trusted relative Rails view paths"
          end
          methods = { normalize: [ 1, %i[field time_zone] ], valid?: [ 1, %i[field time_zone] ], format: [ 1, %i[field time_zone] ], schema: [ 0, [ :field ] ] }
          unless respond_to?(:new) && accepts?(method(:new), 0, []) && accepts?(instance_method(:initialize), 0, []) &&
              methods.all? { |key, (count, keywords)| public_instance_methods.include?(key) && accepts?(instance_method(key), count, keywords) }
            raise ConfigurationError, "Field type has an incompatible public constructor or hook signature"
          end
          { handler: name, scalar: scalar, version: version, **partials }
        end
      end

      def normalize(value, field:, time_zone:) = value
      def valid?(value, field:, time_zone:) = true
      def format(text, field:, time_zone:) = text
      def schema(field:) = {}
    end
  end
end
