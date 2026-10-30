# frozen_string_literal: true

module RailsAiAdmin
  module Collections
    # Executes bounded, independently committed database items. A recurring host
    # scan recovers queue loss and expired leases; no scheduler is installed.
    class Dispatcher
      def run(job_ref, limit: 100)
        raise ArgumentError, "limit must be between 1 and 100" unless limit.is_a?(Integer) && (1..100).cover?(limit)
        raise ConfigurationError, "Collection execution cannot run inside an existing transaction" if OperationRun.connection.transaction_open?
        limit.times do
          claim = claim_next(job_ref)
          break unless claim
          next if claim.is_a?(Result)
          result = begin
            Operations::Runner.new.execute_admitted(claim: claim)
          rescue ConfigurationError, NameError
            Operations::Result.new(code: "APPROVAL_INVALIDATED")
          rescue StandardError
            Operations::Result.new(code: "OPERATION_FAILED")
          end
          break if result.code == "FENCED"
          break if !result.success? && !finish_rejected(claim, result)
        end
        parent = OperationRun.where.not(selection_id: nil).find_by(id: job_ref, parent_run_id: nil)
        parent ? Contract.result(parent) : Result.new(code: "NOT_FOUND")
      end

      def scan_pending!(limit: 100, inline: false)
        raise ArgumentError, "limit must be between 1 and 1000" unless limit.is_a?(Integer) && (1..1000).cover?(limit)
        now = Time.current
        queued = BatchItem.where(status: "queued").where("next_attempt_at IS NULL OR next_attempt_at <= ?", now)
        stale = BatchItem.where(status: "running").where("lease_expires_at IS NULL OR lease_expires_at <= ?", now)
        ids = queued.or(stale).distinct.limit(limit).pluck(:parent_run_id)
        ids.count do |ref|
          if inline
            run(ref)
            true
          else
            !!ExecutionJob.perform_later(ref)
          end
        end
      end

      # Exposed to trusted worker infrastructure for deterministic lease tests.
      # Claiming grants no write permission; Runner checks the full binding again.
      def claim_next(job_ref)
        Contract.ensure_outside_transaction!
        OperationRun.transaction(requires_new: true) do
          parent = OperationRun.lock.where.not(selection_id: nil).find_by(id: job_ref, parent_run_id: nil)
          next unless parent && Contract::ACTIVE.include?(parent.status)
          begin
            _resource, definition = Contract.definition(parent)
            Contract.verify_manifest!(parent)
          rescue AccessDenied, ConfigurationError, NameError
            Contract.quarantine!(parent, "APPROVAL_INVALIDATED")
            next
          end
          if parent.cancellation_requested_at || !parent.execution_deadline || parent.execution_deadline <= Time.current
            Contract.stop_remaining!(parent, parent.cancellation_requested_at ? "CANCELLED" : "EXECUTION_EXPIRED")
            next
          end
          now = Time.current
          next if BatchItem.where(parent_run_id: parent.id, status: "running").where("lease_expires_at > ?", now).exists?
          ready = BatchItem.where(parent_run_id: parent.id, status: "queued").where("next_attempt_at IS NULL OR next_attempt_at <= ?", now)
          expired = BatchItem.where(parent_run_id: parent.id, status: "running").where("lease_expires_at IS NULL OR lease_expires_at <= ?", now)
          item = ready.or(expired).order(:position).lock.first
          next unless item
          if item.attempts >= definition.handler_class.max_attempts
            item.update!(status: "failed", last_code: "ATTEMPTS_EXHAUSTED", completed_at: now)
            Contract.refresh!(parent)
            next Result.new(code: "ATTEMPTS_EXHAUSTED", job_ref: parent.id, status: parent.status)
          end
          item.update!(status: "running", lease_owner: SecureRandom.uuid, generation: item.generation + 1,
            attempts: item.attempts + 1, lease_expires_at: now + definition.handler_class.lease_duration, next_attempt_at: nil)
          parent.update!(status: "running")
          Claim.new(item)
        end
      rescue ActiveRecord::StatementInvalid => error
        raise unless Contract.contention?(error)
        nil
      end

      private

      def finish_rejected(claim, result)
        OperationRun.transaction(requires_new: true) do
          parent = OperationRun.lock.find(claim.parent_ref)
          item = BatchItem.lock.find(claim.item_ref)
          next unless item.status == "running" && item.lease_owner == claim.owner && item.generation == claim.generation
          # An expired response cannot finalize the old lease. The durable running
          # item is left for the scanner to reclaim, without changing its receipt.
          next unless item.lease_expires_at && item.lease_expires_at > Time.current
          lease_deadline = item.lease_expires_at
          finalized = if %w[APPROVAL_INVALIDATED AUTHORIZATION_REVOKED CANCELLED EXECUTION_EXPIRED].include?(result.code)
            Contract.stop_remaining!(parent, result.code)
          else
            retryable = result.code == "OPERATION_FAILED" && item.attempts < current_attempt_limit(parent) && parent.execution_deadline > Time.current
            item.update!(status: retryable ? "queued" : (result.code == "NOT_FOUND" ? "cancelled" : "failed"), last_code: result.code,
              next_attempt_at: retryable ? Time.current + [ 2**item.attempts, 60 ].min : nil,
              completed_at: retryable ? nil : Time.current)
            AuditEvent.create!(actor_ref: parent.actor_ref, tenant_ref: parent.tenant_ref, resource_key: parent.resource_key,
              operation: parent.operation, status: "rejected", code: result.code, correlation_ref: item.operation_run_id,
              origin: parent.origin, changed_fields: [], created_at: Time.current)
            Contract.refresh!(parent)
          end
          raise AccessDenied, "FENCED" unless lease_deadline > Time.current
          finalized
        end
      rescue AccessDenied => error
        raise unless error.code == "FENCED"
        nil
      rescue ActiveRecord::StatementInvalid => error
        raise unless Contract.contention?(error)
        nil
      end

      def current_attempt_limit(parent)
        _resource, definition = Contract.definition(parent)
        definition.handler_class.max_attempts
      rescue AccessDenied
        0
      end
    end
  end
end
