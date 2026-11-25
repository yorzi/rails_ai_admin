# frozen_string_literal: true

module RailsAiAdmin
  module Collections
    # One parent owns approval. Per-target child intents are created only at
    # admission, and can execute solely through an admitted worker lease.
    class Runner
      PREFLIGHT_BUDGET = 30
      SAMPLE_PREVIEW_LIMIT = 25
      INSERT_BATCH_SIZE = 500
      Target = Data.define(:id, :label, :changes)
      Proposal = Data.define(:intent, :values, :targets, :total_count, :sampled) do
        def initialize(intent:, values:, targets:, total_count: targets.size, sampled: false) = super
      end
      RetryProposal = Data.define(:proposal, :selection, :omitted_count, :source_job_ref)

      class Rejected < StandardError
        attr_reader :result
        def initialize(code, errors = {})
          @result = Result.new(code: code, errors: errors)
          super(code)
        end
      end

      def preflight(context:, resource:, operation:, selection_ref:, input:, origin: :ui, retry_of_run_id: nil)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PREFLIGHT_BUDGET
        raise ConfigurationError, "Unsupported origin" unless Operations::Runner::ORIGINS.include?(origin.to_s)
        definition = RailsAiAdmin.operation_registry.fetch(resource, operation)
        raise ConfigurationError, "Expected a collection operation" unless Contract.supported_definition?(definition)
        Contract.ensure_pool!(resource)
        records_by_id = {}
        selection = Selections::Builder.new.revalidate(context: context, selection_ref: selection_ref,
          resource: resource, max_items: RailsAiAdmin.configuration.async_bulk_limit) { |record| records_by_id[record.id.to_s] = record }
        values = collection_input(context, resource, definition, input)
        sampled = selection.targets.size > Selections::Builder::LIMIT
        targets = previews(context, resource, definition, selection, values, records_by_id: records_by_id,
          sampled: sampled, deadline: deadline)
        raise Rejected.new("VALIDATION_FAILED", "base" => [ "preview is too large" ]) if JSON.generate(targets.map(&:changes)).bytesize > 262_144
        source = Selection.find(selection.selection_ref)
        manifest = selection.targets.map { |target| [ target.id, target.expected_version ] }
        payload = wire(values)
        raise Rejected.new("VALIDATION_FAILED", "base" => [ "input is too large" ]) if JSON.generate(payload).bytesize > 4096
        mode = definition.approval_mode.to_s
        multi_actor = OperationRun.column_names.include?("approval_mode")
        if mode != "self" && !multi_actor
          raise ConfigurationError, "Multi-actor approvals require the latest engine migrations"
        end
        attrs = {
          id: SecureRandom.uuid, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref,
          security_version: context.security_version, resource_key: resource.key.to_s, operation: definition.key,
          operation_version: Operations::RunnerFingerprint.call(resource, definition), selection_id: selection.selection_ref,
          selection_digest: selection.manifest_digest, manifest_resource_version: source.resource_version,
          manifest_payload: manifest, input_payload: payload, input_digest: InputSchema.digest(values), origin: origin.to_s,
          expires_at: Time.current + RailsAiAdmin.configuration.intent_ttl
        }
        if multi_actor
          attrs[:proposed_by_actor_ref] = context.actor_ref
          attrs[:approval_mode] = mode
        end
        if retry_of_run_id && OperationRun.column_names.include?("retry_of_run_id")
          attrs[:retry_of_run_id] = retry_of_run_id
        end
        intent = OperationRun.create!(**attrs)
        Proposal.new(intent: intent, values: values, targets: targets.freeze, total_count: selection.targets.size, sampled: sampled)
      rescue Rejected => error
        error.result
      rescue AccessDenied => error
        Result.new(code: error.code)
      rescue StandardError => error
        raise if error.is_a?(ConfigurationError)
        Result.new(code: Contract.contention?(error) ? "CONFLICT" : "OPERATION_FAILED")
      end

      def admit(context:, intent_ref:, input:, human_confirmed: false, binding: nil, approval_note: nil)
        admitted = false
        Contract.ensure_outside_transaction!
        note = validate_approval_note!(approval_note)
        result = OperationRun.transaction(requires_new: true) do
          run = Contract.for_admission(context, intent_ref)
          resource, definition = Contract.definition(run)
          verify_binding!(run, binding) if binding
          Contract.verify_manifest!(run)
          multi_actor = OperationRun.column_names.include?("approval_mode")
          mode = multi_actor ? run.approval_mode.to_s : "self"
          proposer_ref = (multi_actor && run.proposed_by_actor_ref.presence) || run.actor_ref
          if run.status != "proposed"
            unless run.actor_ref == context.actor_ref || proposer_ref == context.actor_ref
              raise AccessDenied
            end
            raise Rejected.new("APPROVAL_INVALIDATED") if run.actor_ref == context.actor_ref && run.security_version != context.security_version
            Authorization::Access.new(context, resource).authorize_receipt!(run.operation, nil)
            raise Rejected.new("CONFLICT") unless Contract::ACTIVE.include?(run.status) || (Contract::TERMINAL.include?(run.status) && run.approved_digest)
            Contract.verify_approved!(run, definition, context)
            verify_input!(run, definition, context, input, replay: true)
            next Contract.result(run, replayed: true)
          end
          raise Rejected.new("APPROVAL_EXPIRED") unless run.expires_at > Time.current
          raise Rejected.new("APPROVAL_REQUIRED") unless human_confirmed == true
          if mode == "separate_actor" && context.actor_ref == proposer_ref
            raise Rejected.new("SELF_APPROVAL_FORBIDDEN")
          end
          access = Authorization::Access.new(context, resource)
          access.authorize_approval!(definition.key, nil, proposed_by_actor_ref: proposer_ref) if mode != "self"
          values = collection_input(context, resource, definition, input)
          raise Rejected.new("APPROVAL_INVALIDATED") unless InputSchema.digest(values) == run.input_digest
          selection = Selections::Builder.new.validate_for_admission(context: context, selection_ref: run.selection_id,
            resource: resource, manifest_digest: run.selection_digest, allow_reviewer: mode != "self",
            max_items: RailsAiAdmin.configuration.async_bulk_limit) do |record|
            access.authorize_approval!(definition.key, record, proposed_by_actor_ref: proposer_ref) if mode != "self"
            access.authorize!(definition.key, record)
            current = Contract.input_schema(definition, access, record).coerce(wire(values), time_zone: context.time_zone)
            raise Rejected.new("APPROVAL_INVALIDATED") unless current.valid? && InputSchema.digest(current.values) == run.input_digest
          end
          raise Rejected.new("APPROVAL_INVALIDATED") unless selection.targets.map { |target| [ target.id, target.expected_version ] } == run.manifest_payload
          deadline = Time.current + Contract.execution_window(definition)
          source_items = SelectionItem.where(selection_id: run.selection_id).order(:position).limit(Selections::Builder::MAX_ASYNC_LIMIT + 1).to_a
          unless source_items.map { |item| [ item.target_id, item.expected_version ] } == run.manifest_payload && source_items.map(&:position) == (0...source_items.size).to_a
            raise Rejected.new("APPROVAL_INVALIDATED")
          end
          now = Time.current
          if mode != "self"
            run.actor_ref = context.actor_ref
            run.security_version = context.security_version
          end
          children, items = [], []
          source_items.each do |item|
            id = SecureRandom.uuid
            child = { id: id, parent_run_id: run.id, actor_ref: run.actor_ref, tenant_ref: run.tenant_ref,
              security_version: run.security_version, resource_key: run.resource_key, operation: run.operation,
              operation_version: run.operation_version, target_id: item.target_id, expected_version: item.expected_version,
              input_digest: run.input_digest, origin: run.origin, expires_at: deadline, created_at: now, updated_at: now }
            if multi_actor
              child[:proposed_by_actor_ref] = proposer_ref
              child[:approval_mode] = mode
            end
            children << child
            items << { id: SecureRandom.uuid, parent_run_id: run.id, operation_run_id: id, selection_item_id: item.id,
              target_id: item.target_id, expected_version: item.expected_version, position: item.position, created_at: now, updated_at: now }
          end
          children.each_slice(INSERT_BATCH_SIZE) { |slice| OperationRun.insert_all!(slice) }
          items.each_slice(INSERT_BATCH_SIZE) { |slice| BatchItem.insert_all!(slice) }
          audit_attrs = {
            actor_ref: run.actor_ref, tenant_ref: run.tenant_ref, resource_key: run.resource_key,
            operation: run.operation, status: "admitted", code: "QUEUED", correlation_ref: run.id,
            origin: run.origin, changed_fields: [], created_at: now
          }
          audit_attrs[:proposed_by_actor_ref] = proposer_ref if AuditEvent.column_names.include?("proposed_by_actor_ref")
          audit = AuditEvent.create!(**audit_attrs)
          run.execution_deadline = deadline
          update_attrs = {
            actor_ref: run.actor_ref, security_version: run.security_version,
            status: "queued", audit_event_id: audit.id, approved_by_ref: context.actor_ref,
            approved_digest: Contract.approval_digest(run), confirmed_at: now, execution_deadline: deadline
          }
          if multi_actor
            update_attrs[:proposed_by_actor_ref] = proposer_ref
            update_attrs[:approver_security_version] = context.security_version
            update_attrs[:approval_note] = note if note
          end
          run.update!(**update_attrs)
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

      def retry_failed(context:, job_ref:, origin: :ui)
        Contract.ensure_outside_transaction!
        source = Contract.owned(context, job_ref)
        raise Rejected.new("CONFLICT") unless %w[partially_succeeded failed].include?(source.status)
        resource, definition = Contract.definition(source)
        Contract.verify_manifest!(source)
        Contract.verify_approved!(source, definition, context) if source.approved_digest
        failed_ids = BatchItem.where(parent_run_id: source.id, status: "failed").order(:position).pluck(:target_id)
        raise Rejected.new("NOT_FOUND") if failed_ids.empty?

        eligible_ids = ActiveRecord::Base.while_preventing_writes do
          access = Authorization::Access.new(context, resource)
          access.authorize_selection!
          access.authorize!(definition.key)
          model = resource.model_class
          pk = model.arel_table[model.primary_key]
          records = access.relation.where(pk.in(failed_ids)).to_a.index_by { |record| record.id.to_s }
          failed_ids.select do |target_id|
            record = records[target_id]
            next false unless record
            access.authorize!(:show, record)
            access.authorize!(definition.key, record)
            true
          rescue AccessDenied
            false
          end
        end
        raise Rejected.new("NOT_FOUND") if eligible_ids.empty?
        omitted = failed_ids.size - eligible_ids.size
        selection = Selections::Builder.new.capture(context: context, resource: resource, target_ids: eligible_ids,
          max_items: RailsAiAdmin.configuration.async_bulk_limit)
        proposed = preflight(context: context, resource: resource, operation: definition.key,
          selection_ref: selection.selection_ref, input: source.input_payload, origin: origin, retry_of_run_id: source.id)
        return proposed if proposed.is_a?(Result)
        RetryProposal.new(proposal: proposed, selection: selection, omitted_count: omitted, source_job_ref: source.id)
      rescue Rejected => error
        error.result
      rescue AccessDenied => error
        Result.new(code: error.code)
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
        coercion = Contract.input_schema(definition).coerce(input, time_zone: context.time_zone)
        raise Rejected.new(replay ? "IDEMPOTENCY_CONFLICT" : "APPROVAL_INVALIDATED") unless coercion.valid? && InputSchema.digest(coercion.values) == run.input_digest
      end

      def collection_input(context, resource, definition, input)
        ActiveRecord::Base.while_preventing_writes do
          access = Authorization::Access.new(context, resource)
          access.authorize!(definition.key)
          coercion = Contract.input_schema(definition, access, nil).coerce(input, time_zone: context.time_zone)
          raise Rejected.new("VALIDATION_FAILED", coercion.errors) unless coercion.valid?
          coercion.values
        end
      rescue ActiveRecord::ReadOnlyError
        raise ConfigurationError, "Collection input resolution must be read-only", cause: nil
      end

      def previews(context, resource, definition, selection, values, records_by_id:, sampled:, deadline:)
        runner = Operations::Runner.new
        preview_targets = sampled ? selection.targets.first(SAMPLE_PREVIEW_LIMIT) : selection.targets
        rendered = preview_targets.map do |target|
          raise Rejected.new("TIMEOUT") if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          preview = runner.preview(context: context, resource: resource, operation: definition.key,
            target_id: target.id, expected_version: target.expected_version, input: wire(values))
          raise Rejected.new(preview.code, preview.errors) if preview.is_a?(Operations::Result)
          raise Rejected.new("TIMEOUT") if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          raise Rejected.new("APPROVAL_INVALIDATED") unless InputSchema.digest(preview.values) == InputSchema.digest(values)
          changes = if !definition.custom? && definition.key == "update"
            record = records_by_id[target.id]
            access = Authorization::Access.new(context, resource)
            diff, = Operations::BulkChange.changes(access, record, preview.values)
            diff.transform_values { |pair| { "before" => pair[0], "after" => pair[1] } }
          else
            preview.changes
          end
          Target.new(target.id, target.label, changes)
        end

        if sampled
          ActiveRecord::Base.while_preventing_writes do
            access = Authorization::Access.new(context, resource)
            payload = wire(values)
            expected_digest = InputSchema.digest(values)
            selection.targets.drop(SAMPLE_PREVIEW_LIMIT).each do |target|
              raise Rejected.new("TIMEOUT") if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
              record = records_by_id.fetch(target.id) { raise AccessDenied }
              access.authorize!(definition.key, record)
              raise Rejected.new("CONFLICT") unless RecordVersion.of(record) == target.expected_version
              coerced = Contract.input_schema(definition, access, record).coerce(payload, time_zone: context.time_zone)
              raise Rejected.new("VALIDATION_FAILED", coerced.errors) unless coerced.valid?
              raise Rejected.new("APPROVAL_INVALIDATED") unless InputSchema.digest(coerced.values) == expected_digest
            end
          end
        end
        rendered
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

      def validate_approval_note!(note)
        return nil if note.nil? || (note.is_a?(String) && note.strip.empty?)
        unless note.is_a?(String) && note.valid_encoding? && note.strip.length.between?(1, 500) && !note.match?(Field::TEXT_CONTROLS)
          raise Rejected.new("INVALID_QUERY")
        end
        note.strip
      end
    end
  end
end
