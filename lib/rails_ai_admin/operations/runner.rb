# frozen_string_literal: true

require "securerandom"

module RailsAiAdmin
  module Operations
    # Executes registered database operations through one atomic boundary.
    class Runner
      ORIGINS = %w[ui surface assistant].freeze
      Proposal = Data.define(:intent, :values, :changes)
      Preview = Data.define(:target_id, :expected_version, :values, :changes)

      def prepare(...)
        result = preflight(...)
        raise AccessDenied, result.code if result.is_a?(Result)
        result.intent
      end

      def preflight(context:, resource:, operation:, target_id: nil, expected_version: nil, input: nil, origin: :ui)
        definition = RailsAiAdmin.operation_registry.fetch(resource, operation)
        if definition.custom? && definition.scope == :collection
          raise ConfigurationError, "Collection intents require fixed-manifest preflight and admission"
        end
        result = preview(context: context, resource: resource, operation: operation, target_id: target_id,
          expected_version: expected_version, input: input, origin: origin)
        return result if result.is_a?(Result)
        intent = OperationRun.create!(id: SecureRandom.uuid, actor_ref: context.actor_ref,
          tenant_ref: context.tenant_ref, security_version: context.security_version,
          resource_key: resource.key.to_s, operation: operation.to_s,
          operation_version: operation_version(resource, operation), target_id: result.target_id,
          expected_version: result.expected_version, input_digest: input && InputSchema.digest(result.values),
          origin: origin.to_s, expires_at: Time.current + RailsAiAdmin.configuration.intent_ttl)
        Proposal.new(intent, result.values, result.changes)
      end

      # Computes a safe typed preview without creating an intent or saving domain
      # data. Collection admission and native member preparation share this path.
      def preview(context:, resource:, operation:, target_id: nil, expected_version: nil, input: nil, origin: :ui)
        operation = operation.to_s
        check_origin!(origin)
        definition = RailsAiAdmin.operation_registry.fetch(resource, operation)
        access = Authorization::Access.new(context, resource)
        ensure_connection!(resource, definition)
        read_proposal = lambda do
          record = operation == "create" ? access.relation.new : access.find!(target_id, action: operation)
          access.authorize!(operation, record)
          version = operation == "create" ? nil : parse_version(expected_version)
          raise AccessDenied, "CONFLICT" if version && version != record.lock_version
          raise ConfigurationError, "Create must not have a target" if operation == "create" && target_id
          raise ConfigurationError, "Custom operations require input-bound preflight" if definition.custom? && input.nil?
          values = input.nil? ? nil : coerce!(access, record, definition, input)
          changes = definition.custom? ? preview_changes(access, record, definition, values) : {}
          [ record, version, values, changes ]
        end
        record, version, values, changes = definition.custom? ? ActiveRecord::Base.while_preventing_writes(&read_proposal) : read_proposal.call
        Preview.new(operation == "create" ? nil : record.id.to_s, version, values || {}, changes)
      rescue Rejection => error
        error.result
      rescue ExecutionContext::DeadlineExceeded
        Result.new(code: "TIMEOUT")
      rescue StandardError => error
        raise if !definition&.custom? || error.is_a?(ConfigurationError) || error.is_a?(AccessDenied)
        Result.new(code: "OPERATION_FAILED")
      end

      # Reauthorizes and consumes a human event atomically with the domain write.
      # human_confirmed comes only from a trusted HTTP/Surface adapter, never from
      # an assistant tool parameter. Origin is audit metadata, not authority.
      def execute(context:, intent_ref:, input:, human_confirmed: false, origin: :ui, binding: nil)
        execute_intent(context: context, intent_ref: intent_ref, input: input, human_confirmed: human_confirmed, origin: origin, binding: binding)
      end

      # Internal worker entry: its authority is the admitted parent and lease,
      # never another synthetic human confirmation. No HTTP adapter calls it.
      def execute_admitted(claim:)
        raise ConfigurationError, "Expected a collection lease claim" unless claim.is_a?(Collections::Claim)
        Collections::Contract.ensure_outside_transaction!
        execute_intent(context: claim.context, intent_ref: claim.operation_run_id,
          input: claim.payload, origin: claim.origin, admission: claim)
      rescue AccessDenied => error
        Result.new(code: error.code)
      end

      def execute_intent(context:, intent_ref:, input:, human_confirmed: false, origin: :ui, binding: nil, admission: nil)
        run = access = definition = nil
        transaction_body_finished = false
        raise AccessDenied, "UNAUTHENTICATED" unless context.is_a?(Context)
        reject!("NOT_FOUND") unless intent_ref.is_a?(String) && intent_ref.match?(/\A[0-9a-f-]{36}\z/)
        result = OperationRun.transaction(requires_new: true) do
          admission&.lock!(context)
          run = OperationRun.lock.find_by(id: intent_ref, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref)
          reject!("NOT_FOUND") unless run
          reject!("NOT_FOUND") if run.parent_run_id && !admission
          check_origin!(origin)
          reject!("APPROVAL_INVALIDATED") unless run.security_version == context.security_version
          reject!("APPROVAL_EXPIRED") unless run.expires_at && run.expires_at > Time.current
          check_binding!(run, binding) if binding
          resource = RailsAiAdmin.registry.fetch(run.resource_key)
          definition = RailsAiAdmin.operation_registry.fetch(resource, run.operation)
          ensure_connection!(resource, definition)
          reject!("NOT_FOUND") if definition.custom? && definition.scope == :collection && !admission
          admission&.validate_child!(run, resource, definition)
          reject!("APPROVAL_INVALIDATED") unless run.operation_version == operation_version(resource, run.operation)
          access = Authorization::Access.new(context, resource)
          record = load_record(access, run, definition)
          if definition.custom? && run.status == "succeeded"
            access.authorize_receipt!(run.operation, record)
          else
            access.authorize!(run.operation, record)
          end
          values = coerce!(access, record, definition, input, replay: run.status == "succeeded")
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
          reject!("APPROVAL_REQUIRED") unless admission || human_confirmed == true
          if run.operation != "create" && record.lock_version != run.expected_version
            reject!("CONFLICT")
          end
          # A write claim, not a process mutex, serializes SQLite writers too.
          run.update!(status: "running", input_digest: digest)
          if definition.custom?
            before = record.attributes_before_type_cast.deep_dup
            context_for_handler = ExecutionContext.new(context, resource, record, run: run, duration: definition.handler_class.max_duration)
            outcome = call_handler(definition, context_for_handler, record, values)
            unless outcome.is_a?(Operation::Outcome)
              raise ConfigurationError, "Operation must return success, invalid or conflict"
            end
            raise ConfigurationError, "Unknown operation outcome" unless %w[OK VALIDATION_FAILED CONFLICT].include?(outcome.code)
            if outcome.code != "OK"
              names = outcome.fields & definition.fields(access, record).map { |field| field.name.to_s }
              reject!(outcome.code, errors: names.any? ? names.to_h { |name| [ name, [ "is invalid" ] ] } : { "base" => [ "operation was rejected" ] })
            end
            unless record.persisted? && !record.destroyed? && !record.has_changes_to_save? && outcome.record_id == run.target_id
              reject!("VALIDATION_FAILED", errors: { "base" => [ "operation did not persist its target" ] })
            end
            record.reload
            if before != record.attributes_before_type_cast && record.lock_version <= run.expected_version
              raise ConfigurationError, "Custom writes must advance the target lock_version"
            end
            changed_fields = resource.fields.map { |field| field.name.to_s }.select { |name| before[name] != record.attributes_before_type_cast[name] }
            WorkItem.where(operation_run_id: run.id).update_all(expected_version: record.lock_version)
          else
            record.assign_attributes(values) if run.operation == "update"
            changed_fields = record.changes.keys & values.keys
            persisted = definition.handler_class.new.perform(nil, record, values)
            reject!("VALIDATION_FAILED", errors: { "base" => [ "could not be saved" ] }) unless persisted
          end
          unless run.operation == "destroy" || access.relation.where(resource.model_class.primary_key => record.id).exists?
            reject!("NOT_FOUND")
          end
          audit = AuditEvent.create!(actor_ref: context.actor_ref, tenant_ref: context.tenant_ref,
            resource_key: run.resource_key, operation: run.operation, status: "succeeded", code: "OK",
            record_id: record.id.to_s, correlation_ref: run.id, origin: origin.to_s,
            changed_fields: changed_fields, created_at: Time.current)
          attributes = { status: "succeeded", record_id: record.id.to_s, audit_event_id: audit.id, completed_at: Time.current }
          attributes.merge!(approved_by_ref: context.actor_ref, approved_digest: digest, confirmed_at: Time.current) unless admission
          run.update!(attributes)
          receipt = projection(access, run, record)
          admission&.complete!(run)
          transaction_body_finished = true
          receipt
        end
        result || committed_callback_result(context, run, transaction_body_finished) || reject!("VALIDATION_FAILED", errors: { "base" => [ "transaction was rolled back" ] })
      rescue StandardError => error
        committed = committed_callback_result(context, run, transaction_body_finished)
        return committed if committed
        case error
        when Rejection
          audit_failure(context, run, error.result.code, origin) unless admission
          error.result
        when AccessDenied
          audit_failure(context, run, error.code, origin) unless admission
          Result.new(code: error.code)
        when ActiveRecord::RecordInvalid
          allowed = if definition&.custom?
            access&.operation_fields(run.operation, error.record)&.map { |field| field.name.to_s } || []
          else
            access&.fields(:write, error.record, operation: run.operation)&.map { |field| field.name.to_s } || []
          end
          errors = error.record.errors.attribute_names.map(&:to_s).intersection(allowed).to_h { |name| [ name, [ "is invalid" ] ] }
          audit_failure(context, run, "VALIDATION_FAILED", origin) unless admission
          Result.new(code: "VALIDATION_FAILED", errors: errors.presence || { "base" => [ "is invalid" ] })
        when ActiveRecord::RecordNotDestroyed, ActiveRecord::RecordNotSaved
          audit_failure(context, run, "VALIDATION_FAILED", origin) unless admission
          Result.new(code: "VALIDATION_FAILED", errors: { "base" => [ "operation was not saved" ] })
        when ActiveRecord::RangeError
          audit_failure(context, run, "VALIDATION_FAILED", origin) unless admission
          Result.new(code: "VALIDATION_FAILED", errors: { "base" => [ "value is out of range" ] })
        when ExecutionContext::DeadlineExceeded
          audit_failure(context, run, "TIMEOUT", origin) unless admission
          Result.new(code: "TIMEOUT")
        when ActiveRecord::StaleObjectError, ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
          Result.new(code: "CONFLICT")
        when ActiveRecord::StatementInvalid
          if defined?(SQLite3::BusyException) && error.cause.is_a?(SQLite3::BusyException)
            Result.new(code: "CONFLICT")
          elsif definition&.custom?
            audit_failure(context, run, "OPERATION_FAILED", origin) unless admission
            Result.new(code: "OPERATION_FAILED")
          else
            raise
          end
        else
          if definition&.custom? && !error.is_a?(ConfigurationError)
            audit_failure(context, run, "OPERATION_FAILED", origin) unless admission
            Result.new(code: "OPERATION_FAILED")
          else
            raise
          end
        end
      end

      private :execute_intent

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

      def check_origin!(origin)
        raise ConfigurationError, "Unsupported origin" unless ORIGINS.include?(origin.to_s)
      end

      def check_binding!(run, binding)
        expected = { resource_key: run.resource_key, operation: run.operation, target_id: run.target_id }
        reject!("NOT_FOUND") unless binding.transform_values { |value| value&.to_s } == expected
      end

      def parse_version(value)
        raise AccessDenied, "CONFLICT" unless value.is_a?(Integer) || value.to_s.match?(/\A\d+\z/)
        value.is_a?(String) ? Integer(value, 10) : value
      end

      def ensure_connection!(resource, definition)
        model = resource.model_class
        unless model.connection_pool.equal?(OperationRun.connection_pool) && model.connection_pool.equal?(AuditEvent.connection_pool) && model.connection_pool.equal?(WorkItem.connection_pool) && model.connection_pool.equal?(BatchItem.connection_pool)
          raise ConfigurationError, "Domain, intent and audit must use the same connection pool"
        end
        unless model.locking_enabled? && model.locking_column == "lock_version" && !model.composite_primary_key?
          raise ConfigurationError, "Generic writes require lock_version and a single primary key"
        end
        unless %w[SQLite PostgreSQL].include?(model.connection.adapter_name)
          raise ConfigurationError, "Only SQLite and PostgreSQL are supported for writes"
        end
        if definition.custom?
          definition.handler_class.atomic_models.each do |name|
            related = name.constantize
            unless related.is_a?(Class) && related < ActiveRecord::Base && related.connection_pool.equal?(model.connection_pool)
              raise ConfigurationError, "Every declared atomic model must use the operation connection pool"
            end
          end
        end
      end

      def operation_version(resource, operation)
        definition = RailsAiAdmin.operation_registry.fetch(resource, operation)
        RunnerFingerprint.call(resource, definition)
      end

      def load_record(access, run, definition)
        if run.status == "succeeded" && run.operation == "destroy"
          # Deleted records have no current projection. Require a fresh
          # collection-level destroy decision before returning even a receipt.
          nil
        elsif run.operation == "create"
          access.relation.new
        elsif definition.custom? && run.status == "succeeded"
          access.relation.lock.find_by(access.resource.model_class.primary_key => run.record_id).tap { |record| reject!("NOT_FOUND") unless record }
        else
          access.find!(run.target_id, action: run.operation, lock: true)
        end
      end

      def coerce!(access, record, definition, input, replay: false)
        fields = replay && definition.custom? ? definition.handler_class.input : definition.fields(access, record)
        result = InputSchema.new(fields, partial: definition.key == "update" && !definition.custom?).coerce(input, time_zone: access.context.time_zone)
        reject!(replay ? "IDEMPOTENCY_CONFLICT" : "VALIDATION_FAILED", errors: replay ? {} : result.errors) unless result.valid?
        result.values
      end

      def preview_changes(access, record, definition, values)
        handler_context = ExecutionContext.new(access.context, access.resource, record, duration: definition.handler_class.max_duration)
        changes = ActiveRecord::Base.while_preventing_writes { definition.handler_class.new.preflight(handler_context, record, values) }
        handler_context.check_deadline!
        if changes.is_a?(Operation::Outcome) && %w[VALIDATION_FAILED CONFLICT].include?(changes.code)
          names = changes.fields & definition.fields(access, record).map { |field| field.name.to_s }
          reject!(changes.code, errors: names.any? ? names.to_h { |name| [ name, [ "is invalid" ] ] } : { "base" => [ "operation was rejected" ] })
        end
        raise ConfigurationError, "Preflight must return a field-value hash without mutating its target" unless changes.is_a?(Hash) && !record.has_changes_to_save?
        readable = access.fields(:read, record)
        original = begin
          access.project(record)
        rescue AccessDenied
          {}
        end
        readable.filter_map do |field|
          name = field.name.to_s
          next if field.virtual?
          next unless original.key?(name) && (changes.key?(name) || changes.key?(field.name))
          value = changes.key?(name) ? changes[name] : changes[field.name]
          value = field.coerce(value, time_zone: access.context.time_zone)
          [ name, { "before" => original[name], "after" => value } ]
        end.to_h
      rescue ArgumentError, ActiveRecord::ReadOnlyError
        raise ConfigurationError, "Preflight violated its pure typed preview contract", cause: nil
      end

      def call_handler(definition, context, record, values)
        nested_savepoint = false
        connection = OperationRun.connection
        listener = ->(_event, _start, _finish, _id, payload) { nested_savepoint = true if payload[:connection].equal?(connection) && payload[:sql].match?(/\A(?:SAVEPOINT|RELEASE SAVEPOINT|ROLLBACK TO SAVEPOINT)\b/i) }
        context.check_deadline!
        outcome = ActiveSupport::Notifications.subscribed(listener, "sql.active_record") { definition.handler_class.new.perform(context, record, values) }
        raise ConfigurationError, "Custom handlers must not open requires_new transactions" if nested_savepoint
        context.check_deadline!
        outcome
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
        Result.new(code: "OK", record_id: run.record_id, audit_ref: run.audit_event_id, values: values, replayed: replayed,
          warning: run.warning_code, work_refs: WorkItem.where(operation_run_id: run.id).pluck(:id))
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
          warning: "POST_COMMIT_CALLBACK_FAILED", work_refs: WorkItem.where(operation_run_id: committed.id).pluck(:id))
      end

      def audit_failure(context, run, code, origin)
        return unless run && run.actor_ref == context.actor_ref && run.tenant_ref == context.tenant_ref
        return if run.parent_run_id || run.selection_id
        AuditEvent.create!(actor_ref: context.actor_ref, tenant_ref: context.tenant_ref,
          resource_key: run.resource_key, operation: run.operation, status: "rejected", code: code,
          correlation_ref: run.id, origin: origin.to_s, changed_fields: [], created_at: Time.current)
      end
    end
  end
end
