# frozen_string_literal: true

module RailsAiAdmin
  module Fields
    # Trusted pure host code receives only declared, currently authorized scalar
    # dependencies. It cannot acquire authority from the field declaration.
    class Computation
      extend HookSignatures
      class << self
        def version(value = nil)
          @version = value if value
          @version || "1"
        end

        def metadata
          unless name && version.is_a?(String) && version.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}\z/)
            raise ConfigurationError, "Computation needs a named class and bounded version"
          end
          unless respond_to?(:new) && accepts?(method(:new), 0, []) && accepts?(instance_method(:initialize), 0, []) &&
              public_instance_methods.include?(:call) && instance_method(:call).owner != Computation && accepts?(instance_method(:call), 1, %i[field time_zone])
            raise ConfigurationError, "Computation has an incompatible public constructor or call signature"
          end
          { handler: name, version: version }
        end
      end

      def call(_values, field:, time_zone:)
        raise NotImplementedError
      end

      Definition = Data.define(:handler_name) do
        def handler_class
          klass = handler_name.constantize
          raise ConfigurationError, "Computed field requires a Computation subclass" unless klass.is_a?(Class) && klass < Computation
          klass
        rescue NameError
          raise ConfigurationError, "Computed field class could not be loaded", cause: nil
        end
        def metadata = handler_class.metadata
      end
    end
  end
end
