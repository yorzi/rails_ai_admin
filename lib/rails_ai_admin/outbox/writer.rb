# frozen_string_literal: true

module RailsAiAdmin
  module Outbox
    # Persists intent in Runner's transaction; never contacts a queue/provider.
    class Writer
      def initialize(context, run, resource)
        @context, @run, @resource = context, run, resource
      end

      def enqueue(kind, key: kind, input: nil, **attributes)
        unless OperationRun.connection.transaction_open? && @run.status == "running" && @run.actor_ref == @context.actor_ref && @run.tenant_ref == @context.tenant_ref
          raise ConfigurationError, "Outbox enqueue requires the active operation transaction"
        end
        raise ConfigurationError, "Work key must be a bounded string" unless key.is_a?(String) && key.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,99}\z/)
        raise ConfigurationError, "Use input or keyword attributes, not both" if input && attributes.any?
        definition = RailsAiAdmin.work_registry.fetch(kind)
        result = InputSchema.new(definition.handler_class.input).coerce(input || attributes, time_zone: @context.time_zone)
        raise ConfigurationError, "Invalid outbox payload" unless result.valid?
        payload = result.values.transform_values do |value|
          case value
          when BigDecimal then value.to_s("F")
          when Time, ActiveSupport::TimeWithZone then value.utc.iso8601(6)
          when Date then value.iso8601
          else value
          end
        end
        raise ConfigurationError, "Outbox payload exceeds 4096 bytes" if JSON.generate(payload).bytesize > 4096
        digest = InputSchema.digest(result.values)
        existing = WorkItem.find_by(operation_run_id: @run.id, work_key: key)
        if existing
          unless existing.kind == kind.to_s && existing.payload_digest == digest && existing.handler_version == definition.fingerprint
            raise AccessDenied, "IDEMPOTENCY_CONFLICT"
          end
          return existing.id
        end
        WorkItem.create!(id: SecureRandom.uuid, operation_run_id: @run.id, work_key: key,
          kind: kind.to_s, payload: payload, payload_digest: digest, handler_version: definition.fingerprint,
          deadline_at: Time.current + definition.handler_class.max_age).id
      end
    end
  end
end
