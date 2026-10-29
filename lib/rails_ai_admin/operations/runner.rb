# frozen_string_literal: true

require "securerandom"

module RailsAiAdmin
  module Operations
    # Executes synchronous, database-only CRUD through one atomic boundary.
    class Runner
      OPERATIONS = %w[create update destroy].freeze
      ORIGINS = %w[ui surface assistant].freeze

      # Issues a server-owned form intent or input-bound proposal. Preparation
      # performs no domain save/validation/callback and grants no execution right.
      def prepare(context:, resource:, operation:, target_id: nil, expected_version: nil, input: nil, origin: :ui)
        operation = operation.to_s
        check_operation!(operation, origin)
        access = Authorization::Access.new(context, resource)
        ensure_connection!(resource)
        record = operation == "create" ? access.relation.new : access.find!(target_id, action: operation)
        access.authorize!(operation, record)
        version = operation == "create" ? nil : parse_version(expected_version)
        raise AccessDenied, "CONFLICT" if version && version != record.lock_version
        raise ConfigurationError, "Create must not have a target" if operation == "create" && target_id
        values = input.nil? ? nil : coerce!(access, record, operation, input)
        OperationRun.create!(id: SecureRandom.uuid, actor_ref: context.actor_ref,
          tenant_ref: context.tenant_ref, security_version: context.security_version,
          resource_key: resource.key.to_s, operation: operation,
          operation_version: operation_version(resource, operation),
          target_id: target_id&.to_s, expected_version: version,
          input_digest: values && InputSchema.digest(values), origin: origin.to_s,
          expires_at: Time.current + RailsAiAdmin.configuration.intent_ttl)
      rescue Rejection => error
        raise AccessDenied, error.result.code
      end

      # Reauthorizes and consumes a human event atomically with the domain write.
      # human_confirmed comes only from a trusted HTTP/Surface adapter, never from
      # an assistant tool parameter. Origin is audit metadata, not authority.
      def execute(context:, intent_ref:, input:, human_confirmed: false, origin: :ui, binding: nil)
        run = access = nil
        transaction_body_finished = false
        raise AccessDenied, "UNAUTHENTICATED" unless context.is_a?(Context)
        reject!("NOT_FOUND") unless intent_ref.is_a?(String) && intent_ref.match?(/\A[0-9a-f-]{36}\z/)
        result = OperationRun.transaction(requires_new: true) do
          run = OperationRun.lock.find_by(id: intent_ref, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref)
          reject!("NOT_FOUND") unless run
          check_operation!(run.operation, origin)
          reject!("APPROVAL_INVALIDATED") unless run.security_version == context.security_version
          reject!("APPROVAL_EXPIRED") unless run.expires_at && run.expires_at > Time.current
          check_binding!(run, binding) if binding
          resource = RailsAiAdmin.registry.fetch(run.resource_key)
          ensure_connection!(resource)
          reject!("APPROVAL_INVALIDATED") unless run.operation_version == operation_version(resource, run.operation)
          access = Authorization::Access.new(context, resource)
          record = load_record(access, run)
          access.authorize!(run.operation, record)
          values = coerce!(access, record, run.operation, input)
          if run.operation == "create"
            record.assign_attributes(values)
            access.authorize!(:create, record)
            writable = access.fields(:write, record, operation: :create).map { |field| field.name.to_s }
            reject!("NOT_FOUND") unless (values.keys - writable).empty?
          end
          digest = InputSchema.digest(values)
          if run.input_digest && run.input_digest != digest
            reject!(run.status == "succeeded" ? "IDEMPOTENCY_CONFLICT" : "APPROVAL_INVALIDATED")
          end
          if run.status == "succeeded"
            if run.operation == "create"
              record = access.relation.find_by(resource.model_class.primary_key => run.record_id)
              reject!("NOT_FOUND") unless record
            end
            next projection(access, run, record, replayed: true)
          end
          reject!("CONFLICT") unless run.status == "proposed"
          reject!("APPROVAL_REQUIRED") unless human_confirmed == true
          if run.operation != "create" && record.lock_version != run.expected_version
            reject!("CONFLICT")
          end
          # A write claim, not a process mutex, serializes SQLite writers too.
          run.update!(status: "running", input_digest: digest)
          record.assign_attributes(values) if run.operation == "update"
          changed_fields = record.changes.keys & values.keys
          persisted = run.operation == "destroy" ? record.destroy! : record.save!
          reject!("VALIDATION_FAILED", errors: { "base" => [ "could not be saved" ] }) unless persisted
          unless run.operation == "destroy" || access.relation.where(resource.model_class.primary_key => record.id).exists?
            reject!("NOT_FOUND")
          end
          audit = AuditEvent.create!(actor_ref: context.actor_ref, tenant_ref: context.tenant_ref,
            resource_key: run.resource_key, operation: run.operation, status: "succeeded", code: "OK",
            record_id: record.id.to_s, correlation_ref: run.id, origin: origin.to_s,
            changed_fields: changed_fields, created_at: Time.current)
          run.update!(status: "succeeded", record_id: record.id.to_s, audit_event_id: audit.id,
            approved_by_ref: context.actor_ref, approved_digest: digest,
            confirmed_at: Time.current, completed_at: Time.current)
          receipt = projection(access, run, record)
          transaction_body_finished = true
          receipt
        end
        result || committed_callback_result(context, run, transaction_body_finished) || reject!("VALIDATION_FAILED", errors: { "base" => [ "transaction was rolled back" ] })
      rescue StandardError => error
        committed = committed_callback_result(context, run, transaction_body_finished)
        return committed if committed
        case error
        when Rejection
          audit_failure(context, run, error.result.code, origin)
          error.result
        when AccessDenied
          audit_failure(context, run, error.code, origin)
          Result.new(code: error.code)
        when ActiveRecord::RecordInvalid
          allowed = access&.fields(:write, error.record, operation: run.operation)&.map { |field| field.name.to_s } || []
          errors = error.record.errors.attribute_names.map(&:to_s).intersection(allowed).to_h { |name| [ name, [ "is invalid" ] ] }
          audit_failure(context, run, "VALIDATION_FAILED", origin)
          Result.new(code: "VALIDATION_FAILED", errors: errors.presence || { "base" => [ "is invalid" ] })
        when ActiveRecord::RecordNotDestroyed, ActiveRecord::RecordNotSaved
          audit_failure(context, run, "VALIDATION_FAILED", origin)
          Result.new(code: "VALIDATION_FAILED", errors: { "base" => [ "operation was not saved" ] })
        when ActiveRecord::RangeError
          audit_failure(context, run, "VALIDATION_FAILED", origin)
          Result.new(code: "VALIDATION_FAILED", errors: { "base" => [ "value is out of range" ] })
        when ActiveRecord::StaleObjectError, ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
          Result.new(code: "CONFLICT")
        when ActiveRecord::StatementInvalid
          raise unless defined?(SQLite3::BusyException) && error.cause.is_a?(SQLite3::BusyException)
          Result.new(code: "CONFLICT")
        else
          raise
        end
      end

      private

      class Rejection < StandardError # :nodoc:
        attr_reader :result
        def initialize(result)
          @result = result
          super(result.code)
        end
      end

      def reject!(code, errors: {})
        raise Rejection, Result.new(code: code, errors: errors)
      end

      def check_operation!(operation, origin)
        raise ConfigurationError, "Unsupported operation or origin" unless OPERATIONS.include?(operation) && ORIGINS.include?(origin.to_s)
      end

      def check_binding!(run, binding)
        expected = { resource_key: run.resource_key, operation: run.operation, target_id: run.target_id }
        reject!("NOT_FOUND") unless binding.transform_values { |value| value&.to_s } == expected
      end

      def parse_version(value)
        raise AccessDenied, "CONFLICT" unless value.is_a?(Integer) || value.to_s.match?(/\A\d+\z/)
        value.is_a?(String) ? Integer(value, 10) : value
      end

      def ensure_connection!(resource)
        model = resource.model_class
        unless model.connection_pool.equal?(OperationRun.connection_pool) && model.connection_pool.equal?(AuditEvent.connection_pool)
          raise ConfigurationError, "Domain, intent and audit must use the same connection pool"
        end
        unless model.locking_enabled? && model.locking_column == "lock_version" && !model.composite_primary_key?
          raise ConfigurationError, "Generic writes require lock_version and a single primary key"
        end
        unless %w[SQLite PostgreSQL].include?(model.connection.adapter_name)
          raise ConfigurationError, "Only SQLite and PostgreSQL are supported for writes"
        end
      end

      def operation_version(resource, operation)
        "crud:1:#{InputSchema.digest(model: resource.model, fields: resource.fields.map { |field| [ field.name, field.type, field.options ] }, operation: operation)}"
      end

      def load_record(access, run)
        if run.status == "succeeded" && run.operation == "destroy"
          # Deleted records have no current projection. Require a fresh
          # collection-level destroy decision before returning even a receipt.
          nil
        elsif run.operation == "create"
          access.relation.new
        else
          access.find!(run.target_id, action: run.operation, lock: true)
        end
      end

      def coerce!(access, record, operation, input)
        fields = operation == "destroy" ? [] : access.fields(:write, record, operation: operation)
        result = InputSchema.new(fields, partial: operation == "update").coerce(input, time_zone: access.context.time_zone)
        reject!("VALIDATION_FAILED", errors: result.errors) unless result.valid?
        result.values
      end

      def projection(access, run, record, replayed: false)
        values = if run.operation == "destroy"
          {}
        else
          begin
            access.project(record)
          rescue AccessDenied
            {}
          end
        end
        Result.new(code: "OK", record_id: run.record_id, audit_ref: run.audit_event_id, values: values, replayed: replayed, warning: run.warning_code)
      end

      def committed_callback_result(context, run, body_finished)
        return unless body_finished && run && !OperationRun.connection.transaction_open?
        committed = OperationRun.uncached do
          OperationRun.find_by(id: run.id, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref, status: "succeeded")
        end
        return unless committed
        committed.update!(warning_code: "POST_COMMIT_CALLBACK_FAILED")
        # after_commit exceptions cannot turn an already committed business write
        # into a failure. Keep its receipt, without running callbacks or exposing
        # record content again. External-effect reconciliation belongs to host.
        Result.new(code: "OK", record_id: committed.record_id, audit_ref: committed.audit_event_id,
          warning: "POST_COMMIT_CALLBACK_FAILED")
      end

      def audit_failure(context, run, code, origin)
        return unless run && run.actor_ref == context.actor_ref && run.tenant_ref == context.tenant_ref
        AuditEvent.create!(actor_ref: context.actor_ref, tenant_ref: context.tenant_ref,
          resource_key: run.resource_key, operation: run.operation, status: "rejected", code: code,
          correlation_ref: run.id, origin: origin.to_s, changed_fields: [], created_at: Time.current)
      end
    end
  end
end
