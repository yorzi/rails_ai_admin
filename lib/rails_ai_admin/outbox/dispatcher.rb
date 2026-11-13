# frozen_string_literal: true

module RailsAiAdmin
  module Outbox
    # Fencing protects database receipts. Replaying external requests still needs
    # the downstream system to honor the stable delivery key.
    class Dispatcher
      Result = Data.define(:work_ref, :status, :code) do
        def success? = status == "succeeded"
      end
      class Blocked < StandardError
        attr_reader :code
        def initialize(code)
          @code = code
          super(code)
        end
      end
      class LeaseLost < StandardError; end

      def run(work_ref)
        raise ConfigurationError, "Outbox delivery cannot run inside a database transaction" if WorkItem.connection.transaction_open?
        item = claim(work_ref)
        return item if item.is_a?(Result)
        return Result.new(work_ref, "missing", "NOT_FOUND") unless item
        definition = RailsAiAdmin.work_registry.fetch(item.kind)
        authorization = -> { authorize(item) }
        context, resource, record = ActiveRecord::Base.while_preventing_writes { authorization.call }
        values = InputSchema.new(definition.handler_class.input).coerce(item.payload, time_zone: context.time_zone)
        raise Blocked, "PAYLOAD_INVALID" unless values.valid? && InputSchema.digest(values.values) == item.payload_digest
        delivery = DeliveryContext.new(item, context, resource, record, authorization: authorization)
        ActiveRecord::Base.while_preventing_writes { definition.handler_class.new.perform(delivery, values.values) }
        raise ConfigurationError, "Work must complete exactly one ctx.effect" unless delivery.effect_completed?
        finish(item, "succeeded", "OK")
      rescue AccessDenied
        delivery&.effect_completed? ? finish(item, "succeeded", "POST_EFFECT_CALLBACK_FAILED") : fail_delivery(item, "AUTHORIZATION_REVOKED", denied: true)
      rescue Blocked => error
        delivery&.effect_completed? ? finish(item, "succeeded", "POST_EFFECT_CALLBACK_FAILED") : fail_delivery(item, error.code, reconcile: true)
      rescue LeaseLost
        fence_lost(item)
      rescue StandardError
        raise unless item.is_a?(WorkItem)
        delivery&.effect_completed? ? finish(item, "succeeded", "POST_EFFECT_CALLBACK_FAILED") : fail_delivery(item, "DELIVERY_FAILED")
      end

      def scan_pending!(limit: 100, inline: false)
        raise ArgumentError, "limit must be between 1 and 1000" unless limit.is_a?(Integer) && (1..1000).cover?(limit)
        now = Time.current
        due = WorkItem.where(status: "pending").where("next_attempt_at IS NULL OR next_attempt_at <= ? OR deadline_at <= ?", now, now)
        stale = WorkItem.where(status: "running").where("lease_expires_at IS NULL OR lease_expires_at <= ?", now)
        ids = due.or(stale).order(:created_at, :id).limit(limit).pluck(:id)
        ids.count do |id|
          if inline
            run(id)
            true
          else
            !!DeliveryJob.perform_later(id)
          end
        end
      end

      private

      def claim(work_ref)
        WorkItem.transaction do
          item = WorkItem.lock.find_by(id: work_ref)
          next unless item
          now = Time.current
          unless %w[pending running].include?(item.status)
            next Result.new(item.id, item.status, item.last_code || "TERMINAL")
          end
          if item.status == "running" && item.lease_expires_at && item.lease_expires_at > now
            next Result.new(item.id, item.status, "IN_PROGRESS")
          end
          if item.deadline_at <= now
            terminal = item.effect_started_at ? "reconciliation_required" : "failed"
            item.update!(status: terminal, last_code: "WORK_EXPIRED", completed_at: now)
            next Result.new(item.id, terminal, "WORK_EXPIRED")
          end
          if item.status == "pending" && item.next_attempt_at && item.next_attempt_at > now
            next Result.new(item.id, item.status, "BACKOFF")
          end
          begin
            definition = RailsAiAdmin.work_registry.fetch(item.kind)
            valid = item.handler_version == definition.fingerprint
          rescue ConfigurationError, NameError
            valid = false
          end
          unless valid
            item.update!(status: "reconciliation_required", last_code: "HANDLER_CHANGED", completed_at: now)
            next Result.new(item.id, item.status, item.last_code)
          end
          if item.effect_started_at && !definition.handler_class.idempotent
            item.update!(status: "reconciliation_required", last_code: "OUTCOME_UNKNOWN", completed_at: now)
            next Result.new(item.id, item.status, item.last_code)
          end
          if item.attempts >= definition.handler_class.max_attempts
            item.update!(status: item.effect_started_at ? "reconciliation_required" : "failed", last_code: "ATTEMPTS_EXHAUSTED", completed_at: now)
            next Result.new(item.id, item.status, item.last_code)
          end
          item.update!(status: "running", lease_owner: SecureRandom.uuid, generation: item.generation + 1,
            attempts: item.attempts + 1, lease_expires_at: now + definition.handler_class.lease_duration,
            next_attempt_at: nil, last_code: nil)
          item
        end
      rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
        Result.new(work_ref, "pending", "CONFLICT")
      rescue ActiveRecord::StatementInvalid => error
        raise unless defined?(SQLite3::BusyException) && error.cause.is_a?(SQLite3::BusyException)
        Result.new(work_ref, "pending", "CONFLICT")
      end

      def authorize(item)
        begin
          work = RailsAiAdmin.work_registry.fetch(item.kind)
          valid = work.fingerprint == item.handler_version
        rescue ConfigurationError, NameError
          valid = false
        end
        raise Blocked, "HANDLER_CHANGED" unless valid
        run = OperationRun.find(item.operation_run_id)
        raise Blocked, "OPERATION_NOT_COMMITTED" unless run.status == "succeeded"
        resolver = RailsAiAdmin.configuration.context_adapter&.constantize&.new
        raise Blocked, "JOB_CONTEXT_NOT_CONFIGURED" unless resolver&.respond_to?(:resolve_job)
        context = resolver.resolve_job(actor_ref: run.actor_ref, tenant_ref: run.tenant_ref, security_version: run.security_version)
        unless context.is_a?(Context) && context.actor_ref == run.actor_ref && context.tenant_ref == run.tenant_ref && context.security_version == run.security_version
          raise AccessDenied
        end
        resource = RailsAiAdmin.registry.fetch(run.resource_key)
        unless resource.model_class.connection_pool.equal?(WorkItem.connection_pool) && OperationRun.connection_pool.equal?(WorkItem.connection_pool)
          raise Blocked, "CONNECTION_CHANGED"
        end
        definition = RailsAiAdmin.operation_registry.fetch(resource, run.operation)
        raise Blocked, "OPERATION_CHANGED" unless run.operation_version == Operations::RunnerFingerprint.call(resource, definition)
        access = Authorization::Access.new(context, resource)
        record = access.relation.find_by(resource.model_class.primary_key => run.record_id)
        raise AccessDenied unless record
        access.authorize_delivery!(run.operation, item.kind, record)
        policy = RailsAiAdmin.work_registry.fetch(item.kind).handler_class.record_version_policy
        raise Blocked, "RECORD_CHANGED" if policy == :exact && item.expected_version != RecordVersion.of(record)
        # The admission TTL has been consumed. Delivery has its own deadline.
        raise Blocked, "WORK_EXPIRED" unless item.deadline_at > Time.current
        [ context, resource, record ]
      end

      def owned(item)
        WorkItem.where(id: item.id, status: "running", lease_owner: item.lease_owner, generation: item.generation)
      end

      def finish(item, status, code)
        changed = owned(item).where("lease_expires_at > ?", Time.current).update_all(status: status, last_code: code,
          lease_owner: nil, lease_expires_at: nil, completed_at: Time.current, updated_at: Time.current)
        changed.zero? ? fence_lost(item) : Result.new(item.id, status, code)
      end

      def fail_delivery(item, code, denied: false, reconcile: false)
        return Result.new(nil, "missing", "NOT_FOUND") unless item.is_a?(WorkItem)
        current = WorkItem.find(item.id)
        unknown = current.effect_started_at.present?
        definition = RailsAiAdmin.work_registry.fetch(item.kind)
        terminal = if reconcile || (unknown && (denied || !definition.handler_class.idempotent))
          "reconciliation_required"
        elsif denied
          "cancelled"
        elsif current.attempts >= definition.handler_class.max_attempts
          unknown ? "reconciliation_required" : "failed"
        else
          "pending"
        end
        if terminal == "pending"
          changed = owned(item).where("lease_expires_at > ?", Time.current).update_all(status: terminal, last_code: code,
            next_attempt_at: Time.current + [ 2**current.attempts, 300 ].min, lease_owner: nil, lease_expires_at: nil, updated_at: Time.current)
          changed.zero? ? fence_lost(item) : Result.new(item.id, terminal, code)
        else
          finish(item, terminal, code)
        end
      end

      def fence_lost(item)
        return Result.new(nil, "missing", "NOT_FOUND") unless item.is_a?(WorkItem)
        # Only this expired generation may become uncertain. Never overwrite a
        # newer worker's pending/success state with a stale response.
        owned(item).where("lease_expires_at <= ?", Time.current).where.not(effect_started_at: nil).update_all(
          status: "reconciliation_required", last_code: "OUTCOME_UNKNOWN", completed_at: Time.current, updated_at: Time.current)
        current = WorkItem.find_by(id: item.id)
        Result.new(item.id, current&.status || "missing", "FENCED")
      end
    end
  end
end
