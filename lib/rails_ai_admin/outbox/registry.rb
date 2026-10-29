# frozen_string_literal: true

module RailsAiAdmin
  module Outbox
    class Registry
      Definition = Data.define(:kind, :handler_name) do
        def handler_class
          klass = handler_name.constantize
          raise ConfigurationError, "Work handler must inherit RailsAiAdmin::Work" unless klass.is_a?(Class) && klass < Work
          klass
        end

        def fingerprint
          InputSchema.digest(handler: handler_name, version: handler_class.version, fields: handler_class.input.map { |field| [ field.name, field.type, field.options ] },
            idempotent: handler_class.idempotent, lease: handler_class.lease_duration, attempts: handler_class.max_attempts,
            max_age: handler_class.max_age, record_version: handler_class.record_version_policy)
        end
      end

      def initialize(handlers)
        @entries = handlers.to_h do |kind, name|
          definition = Definition.new(kind.to_s, name)
          definition.handler_class.validate!
          [ kind.to_s, definition ]
        end.freeze
        freeze
      end

      def fetch(kind)
        @entries.fetch(kind.to_s) { raise ConfigurationError, "Unregistered outbox work kind" }
      end

      def definitions = @entries.values
    end
  end
end
