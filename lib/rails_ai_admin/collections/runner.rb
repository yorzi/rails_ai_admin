# frozen_string_literal: true

module RailsAiAdmin
  module Collections
    # One parent owns approval. Per-target child intents are created only at
    # admission, and can execute solely through an admitted worker lease.
    class Runner
      PREFLIGHT_BUDGET = 30
      Target = Data.define(:id, :label, :changes)
      Proposal = Data.define(:intent, :values, :targets)
      class Rejected < StandardError
        attr_reader :result
        def initialize(code, errors = {})
          @result = Result.new(code: code, errors: errors)
          super(code)
        end
      end

      def preflight(context:, resource:, operation:, selection_ref:, input:, origin: :ui)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PREFLIGHT_BUDGET
        raise ConfigurationError, "Unsupported origin" unless Operations::Runner::ORIGINS.include?(origin.to_s)
        definition = RailsAiAdmin.operation_registry.fetch(resource, operation)
        raise ConfigurationError, "Expected a collection operation" unless definition.custom? && definition.scope == :collection
        Contract.ensure_pool!(resource)
        selection = Selections::Builder.new.revalidate(context: context, selection_ref: selection_ref, resource: resource)
        values = collection_input(context, resource, definition, input)
        targets = previews(context, resource, definition, selection, values, deadline: deadline)
        raise Rejected.new("VALIDATION_FAILED", "base" => [ "preview is too large" ]) if JSON.generate(targets.map(&:changes)).bytesize > 262_144
        source = Selection.find(selection.selection_ref)
        manifest = selection.targets.map { |target| [ target.id, target.expected_version ] }
        payload = wire(values)
        raise Rejected.new("VALIDATION_FAILED", "base" => [ "input is too large" ]) if JSON.generate(payload).bytesize > 4096
        intent = OperationRun.create!(id: SecureRandom.uuid, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref,
          security_version: context.security_version, resource_key: resource.key.to_s, operation: definition.key,
          operation_version: Operations::RunnerFingerprint.call(resource, definition), selection_id: selection.selection_ref,
          selection_digest: selection.manifest_digest, manifest_resource_version: source.resource_version,
          manifest_payload: manifest, input_payload: payload, input_digest: InputSchema.digest(values), origin: origin.to_s,
          expires_at: Time.current + RailsAiAdmin.configuration.intent_ttl)
        Proposal.new(intent, values, targets.freeze)
      rescue Rejected => error
        error.result
      rescue AccessDenied => error
        Result.new(code: error.code)
      rescue StandardError => error
        raise if error.is_a?(ConfigurationError)
        Result.new(code: Contract.contention?(error) ? "CONFLICT" : "OPERATION_FAILED")
      end

      def admit(context:, intent_ref:, input:, human_confirmed: false, binding: nil)
        admitted = false
        Contract.ensure_outside_transaction!
        result = OperationRun.transaction(requires_new: true) do
          run = Contract.owned(context, intent_ref, lock: true)
          resource, definition = Contract.definition(run)
          verify_binding!(run, binding) if binding
          Contract.verify_manifest!(run)
          if run.status != "proposed"
            Authorization::Access.new(context, resource).authorize_receipt!(run.operation, nil)
            raise Rejected.new("CONFLICT") unless Contract::ACTIVE.include?(run.status) || (Contract::TERMINAL.include?(run.status) && run.approved_digest)
            Contract.verify_approved!(run, definition, context)
            verify_input!(run, definition, context, input, replay: true)
            next Contract.result(run, replayed: true)
          end
          raise Rejected.new("APPROVAL_EXPIRED") unless run.expires_at > Time.current
          raise Rejected.new("APPROVAL_REQUIRED") unless human_confirmed == true
          values = collection_input(context, resource, definition, input)
          raise Rejected.new("APPROVAL_INVALIDATED") unless InputSchema.digest(values) == run.input_digest
          access = Authorization::Access.new(context, resource)
          selection = Selections::Builder.new.validate_for_admission(context: context, selection_ref: run.selection_id, resource: resource, manifest_digest: run.selection_digest) do |record|
            access.authorize!(definition.key, record)
            current = InputSchema.new(definition.fields(access, record)).coerce(wire(values), time_zone: context.time_zone)
            raise Rejected.new("APPROVAL_INVALIDATED") unless current.valid? && InputSchema.digest(current.values) == run.input_digest
          end
          raise Rejected.new("APPROVAL_INVALIDATED") unless selection.targets.map { |target| [ target.id, target.expected_version ] } == run.manifest_payload
          deadline = Time.current + definition.handler_class.execution_window
          source_items = SelectionItem.where(selection_id: run.selection_id).order(:position).limit(Selections::Builder::LIMIT + 1).to_a
          unless source_items.map { |item| [ item.target_id, item.expected_version ] } == run.manifest_payload && source_items.map(&:position) == (0...source_items.size).to_a
            raise Rejected.new("APPROVAL_INVALIDATED")
          end
          now = Time.current
          children, items = [], []
          source_items.each do |item|
            id = SecureRandom.uuid
            children << { id: id, parent_run_id: run.id, actor_ref: run.actor_ref, tenant_ref: run.tenant_ref,
              security_version: run.security_version, resource_key: run.resource_key, operation: run.operation,
              operation_version: run.operation_version, target_id: item.target_id, expected_version: item.expected_version,
              input_digest: run.input_digest, origin: run.origin, expires_at: deadline, created_at: now, updated_at: now }
            items << { id: SecureRandom.uuid, parent_run_id: run.id, operation_run_id: id, selection_item_id: item.id,
              target_id: item.target_id, expected_version: item.expected_version, position: item.position, created_at: now, updated_at: now }
          end
          OperationRun.insert_all!(children)
          BatchItem.insert_all!(items)
          audit = AuditEvent.create!(actor_ref: run.actor_ref, tenant_ref: run.tenant_ref, resource_key: run.resource_key,
            operation: run.operation, status: "admitted", code: "QUEUED", correlation_ref: run.id, origin: run.origin, changed_fields: [], created_at: now)
          run.execution_deadline = deadline
          run.update!(status: "queued", audit_event_id: audit.id, approved_by_ref: context.actor_ref,
            approved_digest: Contract.approval_digest(run), confirmed_at: now, execution_deadline: deadline)
          admitted = true
          Contract.result(run)
        end
        result || Result.new(code: "CONFLICT")
      rescue Rejected => error
        error.result
      rescue AccessDenied => error
        Result.new(code: error.code)
      rescue StandardError => error
        if admitted && !OperationRun.connection.transaction_open?
          begin
            committed = OperationRun.find_by(id: intent_ref, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref)
          rescue ActiveRecord::ActiveRecordError
            return Result.new(code: "OUTCOME_UNKNOWN", job_ref: intent_ref, status: "unknown")
          end
          if committed && committed.approved_digest && committed.status != "proposed"
            return Contract.result(committed)
          end
        end
        raise if error.is_a?(ConfigurationError)
        Result.new(code: Contract.contention?(error) ? "CONFLICT" : "OPERATION_FAILED")
      end

      def cancel(context:, job_ref:)
        cancelling = false
        Contract.ensure_outside_transaction!
        OperationRun.transaction(requires_new: true) do
          run = Contract.owned(context, job_ref, lock: true)
          resource, = Contract.definition(run)
          Authorization::Access.new(context, resource).authorize_cancel!(run.operation)
          changed = run.status == "proposed" || Contract::ACTIVE.include?(run.status)
          if run.status == "proposed"
            run.update!(status: "cancelled", cancellation_requested_at: Time.current, completed_at: Time.current)
          elsif Contract::ACTIVE.include?(run.status)
            run.update!(cancellation_requested_at: Time.current)
            Contract.stop_remaining!(run, "CANCELLED")
          end
          if changed
            AuditEvent.create!(actor_ref: context.actor_ref, tenant_ref: context.tenant_ref, resource_key: run.resource_key,
              operation: run.operation, status: "cancelled", code: "CANCELLED", correlation_ref: run.id, origin: "ui", changed_fields: [], created_at: Time.current)
          end
          cancelling = changed
          Result.new(code: "CANCELLED", job_ref: run.id, status: run.status)
        end
      rescue AccessDenied => error
        Result.new(code: error.code)
      rescue StandardError => error
        if cancelling && !OperationRun.connection.transaction_open?
          begin
            committed = OperationRun.find_by(id: job_ref, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref)
          rescue ActiveRecord::ActiveRecordError
            return Result.new(code: "OUTCOME_UNKNOWN", job_ref: job_ref, status: "unknown")
          end
          if committed&.cancellation_requested_at
            return Result.new(code: "CANCELLED", job_ref: committed.id, status: committed.status)
          end
        end
        raise if error.is_a?(ConfigurationError)
        Result.new(code: Contract.contention?(error) ? "CONFLICT" : "OPERATION_FAILED")
      end

      private

      def verify_binding!(run, binding)
        expected = { resource_key: run.resource_key, operation: run.operation, selection_id: run.selection_id }
        raise AccessDenied unless binding.transform_values { |value| value&.to_s } == expected
      end

      def verify_input!(run, definition, context, input, replay: false)
        coercion = InputSchema.new(definition.handler_class.input).coerce(input, time_zone: context.time_zone)
        raise Rejected.new(replay ? "IDEMPOTENCY_CONFLICT" : "APPROVAL_INVALIDATED") unless coercion.valid? && InputSchema.digest(coercion.values) == run.input_digest
      end

      def collection_input(context, resource, definition, input)
        ActiveRecord::Base.while_preventing_writes do
          access = Authorization::Access.new(context, resource)
          access.authorize!(definition.key)
          coercion = InputSchema.new(definition.fields(access, nil)).coerce(input, time_zone: context.time_zone)
          raise Rejected.new("VALIDATION_FAILED", coercion.errors) unless coercion.valid?
          coercion.values
        end
      rescue ActiveRecord::ReadOnlyError
        raise ConfigurationError, "Collection input resolution must be read-only", cause: nil
      end

      def previews(context, resource, definition, selection, values, deadline:)
        runner = Operations::Runner.new
        selection.targets.map do |target|
          raise Rejected.new("TIMEOUT") if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          preview = runner.preview(context: context, resource: resource, operation: definition.key,
            target_id: target.id, expected_version: target.expected_version, input: wire(values))
          raise Rejected.new(preview.code, preview.errors) if preview.is_a?(Operations::Result)
          raise Rejected.new("TIMEOUT") if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          raise Rejected.new("APPROVAL_INVALIDATED") unless InputSchema.digest(preview.values) == InputSchema.digest(values)
          Target.new(target.id, target.label, preview.changes)
        end
      end

      def wire(values)
        values.transform_values do |value|
          case value
          when BigDecimal then value.to_s("F")
          when Time, ActiveSupport::TimeWithZone then value.utc.iso8601(6)
          when Date then value.iso8601
          else value
          end
        end
      end
    end
  end
end
