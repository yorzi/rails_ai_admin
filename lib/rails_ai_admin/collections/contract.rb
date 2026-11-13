# frozen_string_literal: true

module RailsAiAdmin
  module Collections
    module Contract
      ACTIVE = %w[queued running].freeze
      TERMINAL = %w[succeeded failed partially_succeeded cancelled reconciliation_required].freeze

      def self.owned(context, ref, lock: false)
        raise AccessDenied, "UNAUTHENTICATED" unless context.is_a?(Context)
        raise AccessDenied unless ref.is_a?(String) && ref.match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/)
        relation = lock ? OperationRun.lock : OperationRun.all
        run = relation.where.not(selection_id: nil).find_by(id: ref, parent_run_id: nil, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref)
        raise AccessDenied unless run
        raise AccessDenied, "APPROVAL_INVALIDATED" unless run.security_version == context.security_version
        run
      end

      def self.definition(run)
        resource = RailsAiAdmin.registry.fetch(run.resource_key)
        definition = RailsAiAdmin.operation_registry.fetch(resource, run.operation)
        unless definition.custom? && definition.scope == :collection && run.operation_version == Operations::RunnerFingerprint.call(resource, definition)
          raise AccessDenied, "APPROVAL_INVALIDATED"
        end
        ensure_pool!(resource)
        [ resource, definition ]
      end

      def self.ensure_outside_transaction!
        raise ConfigurationError, "Collection admission, cancellation and worker steps must own their transaction" if OperationRun.connection.transaction_open?
      end

      def self.ensure_pool!(resource)
        model = resource.model_class
        unless [ OperationRun, AuditEvent, WorkItem, BatchItem, Selection, SelectionItem ].all? { |klass| klass.connection_pool.equal?(model.connection_pool) } &&
            RecordVersion.supported?(model) && %w[SQLite PostgreSQL].include?(model.connection.adapter_name)
          raise ConfigurationError, "Collection storage and domain must share one SQLite/PostgreSQL pool with lock_version or updated_at"
        end
      end

      def self.verify_manifest!(run)
        manifest = run.manifest_payload
        unless manifest.is_a?(Array) && manifest.size.between?(1, Selections::Builder::LIMIT) && manifest.all? { |pair| pair.is_a?(Array) && pair.size == 2 && pair[0].is_a?(String) && pair[0].bytesize.between?(1, 150) && pair[1].is_a?(Integer) && pair[1] >= 0 } &&
            manifest.map(&:first).uniq.size == manifest.size && manifest.sort_by(&:first) == manifest &&
            InputSchema.digest(resource_version: run.manifest_resource_version, targets: manifest) == run.selection_digest
          raise AccessDenied, "APPROVAL_INVALIDATED"
        end
        manifest
      end

      def self.approval_digest(run)
        InputSchema.digest(actor: run.actor_ref, tenant: run.tenant_ref, epoch: run.security_version,
          resource: run.resource_key, operation: run.operation, version: run.operation_version,
          selection: run.selection_id, input_digest: run.input_digest, selection_digest: run.selection_digest,
          deadline: run.execution_deadline)
      end

      def self.verify_approved!(run, definition, context)
        verify_manifest!(run)
        values = InputSchema.new(definition.handler_class.input).coerce(run.input_payload, time_zone: context.time_zone)
        unless run.confirmed_at && run.approved_by_ref == run.actor_ref && run.approved_digest == approval_digest(run) &&
            run.execution_deadline && values.valid? && InputSchema.digest(values.values) == run.input_digest
          raise AccessDenied, "APPROVAL_INVALIDATED"
        end
      end

      # Caller holds the parent lock. Each successful child updates its own receipt
      # and these aggregate statuses inside that same business transaction.
      def self.refresh!(run)
        counts = BatchItem.where(parent_run_id: run.id).group(:status).count
        raise ConfigurationError, "Collection item count changed" unless counts.values.sum == run.manifest_payload.size
        status = if counts.fetch("running", 0) > 0
          "running"
        elsif counts.fetch("queued", 0) > 0
          "queued"
        elsif counts.fetch("succeeded", 0) == run.manifest_payload.size
          "succeeded"
        elsif counts.fetch("succeeded", 0) > 0
          "partially_succeeded"
        elsif counts.fetch("cancelled", 0) > 0
          "cancelled"
        else
          "failed"
        end
        run.update!(status: status, completed_at: TERMINAL.include?(status) ? Time.current : nil)
        status
      end

      def self.quarantine!(run, code)
        BatchItem.where(parent_run_id: run.id, status: ACTIVE).update_all(status: "cancelled", last_code: code,
          completed_at: Time.current, lease_owner: nil, lease_expires_at: nil)
        run.update!(status: "reconciliation_required", completed_at: Time.current)
      end

      def self.stop_remaining!(run, code)
        # A domain transaction holds this same parent lock. Once acquired, an
        # uncommitted claimed item can be fenced without racing a business commit.
        BatchItem.where(parent_run_id: run.id, status: ACTIVE).update_all(status: "cancelled", last_code: code,
          completed_at: Time.current, lease_owner: nil, lease_expires_at: nil)
        refresh!(run)
      end

      def self.contention?(error)
        error.is_a?(ActiveRecord::Deadlocked) || error.is_a?(ActiveRecord::LockWaitTimeout) || error.is_a?(ActiveRecord::RecordNotUnique) ||
          (defined?(SQLite3::BusyException) && error.cause.is_a?(SQLite3::BusyException))
      end

      def self.result(run, replayed: false)
        Result.new(code: ACTIVE.include?(run.status) ? "QUEUED" : "OK", job_ref: run.id, status: run.status, replayed: replayed, warning: run.warning_code)
      end
    end
  end
end
