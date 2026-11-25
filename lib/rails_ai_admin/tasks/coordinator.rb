# frozen_string_literal: true

require "securerandom"

module RailsAiAdmin
  module Tasks
    # Synchronizes and authorizes durable AdminTask coordination records without
    # duplicating OperationRun or BatchItem execution state.
    module Coordinator
      KINDS = %w[change_review bulk_job quality_remediation import recipe_run].freeze
      STATUSES = %w[open awaiting_approval executing verifying succeeded partially_failed failed cancelled expired].freeze
      TABS = %w[needs_approval active completed mine].freeze

      module_function

      def available?
        defined?(AdminTask) && defined?(TaskEvent) && AdminTask.table_exists? && TaskEvent.table_exists?
      rescue ActiveRecord::ActiveRecordError
        false
      end

      def authorized?(context)
        return false unless context.is_a?(Context) && available?
        adapter = RailsAiAdmin.configuration.authorization_adapter&.constantize&.new
        adapter.respond_to?(:view_tasks?) && adapter.view_tasks?(context: context) == true
      end

      def effective_status(task, now: Time.current)
        if task.status == "awaiting_approval" && task.expires_at && task.expires_at <= now
          "expired"
        else
          task.status
        end
      end

      def sync_from_run!(run, actor_ref: nil, surface_id: nil, chat_id: nil, force: false)
        return nil unless available? && run && run.parent_run_id.nil? && run.compensates_run_id.nil?
        mode = OperationRun.column_names.include?("approval_mode") ? run.approval_mode.to_s : "self"
        existing = AdminTask.find_by(operation_run_id: run.id)
        # Undoable runs are tracked so the Completed tab offers their undo.
        undoable = run.status == "succeeded" && OperationRun.column_names.include?("undo_payload") && run.undo_payload.present?
        track = force || existing.present? || mode != "self" || undoable || (run.selection_id.present? && run.status != "proposed")
        return nil unless track

        proposer = (OperationRun.column_names.include?("proposed_by_actor_ref") && run.proposed_by_actor_ref.presence) || run.actor_ref
        status = derive_run_status(run)
        kind = run.selection_id.present? ? "bulk_job" : "change_review"
        metadata = build_metadata(run, mode: mode)
        now = Time.current

        if existing
          previous_status = existing.status
          updates = {
            status: status,
            summary_metadata: (existing.summary_metadata || {}).merge(metadata),
            expires_at: status == "awaiting_approval" ? run.expires_at : existing.expires_at,
            completed_at: %w[succeeded partially_failed failed cancelled expired].include?(status) ? (run.completed_at || now) : nil
          }
          updates[:surface_id] = surface_id if surface_id
          updates[:chat_id] = chat_id.to_s if chat_id
          existing.update!(**updates)
          if previous_status != status
            append_event!(existing, actor_ref: actor_ref || run.approved_by_ref || run.actor_ref,
              event_type: status, code: run.warning_code, message: event_message_for(status, run))
          end
          existing
        else
          task = AdminTask.create!(
            id: SecureRandom.uuid,
            tenant_ref: run.tenant_ref,
            created_by_actor_ref: proposer,
            kind: kind,
            status: status,
            title: build_title(run),
            resource_key: run.resource_key,
            operation: run.operation,
            chat_id: chat_id&.to_s,
            operation_run_id: run.id,
            selection_id: run.selection_id,
            surface_id: surface_id,
            summary_metadata: metadata,
            expires_at: run.expires_at,
            completed_at: %w[succeeded partially_failed failed cancelled expired].include?(status) ? (run.completed_at || now) : nil
          )
          append_event!(task, actor_ref: actor_ref || proposer, event_type: status,
            code: run.warning_code, message: event_message_for(status, run))
          task
        end
      end

      def record_undo!(original_run, undo_run:, actor_ref:)
        return unless available? && original_run
        task = AdminTask.find_by(operation_run_id: original_run.id)
        return unless task
        task.update!(summary_metadata: (task.summary_metadata || {}).merge("undone_by_run_id" => undo_run.id))
        append_event!(task, actor_ref: actor_ref, event_type: "undone", code: "OK",
          message: "Compensated by operation #{undo_run.id}")
      end

      # Withdraws a pending proposal under a row lock, so it serializes with a
      # concurrent approval, and records who withdrew it in the audit log.
      def dismiss!(context:, task:)
        OperationRun.transaction(requires_new: true) do
          run = task.operation_run_id && OperationRun.lock.find_by(id: task.operation_run_id, tenant_ref: context.tenant_ref)
          raise AccessDenied, "CONFLICT" unless run && run.status == "proposed"
          run.update!(status: "cancelled", completed_at: Time.current)
          attrs = { actor_ref: context.actor_ref, tenant_ref: context.tenant_ref, resource_key: run.resource_key,
            operation: run.operation, status: "cancelled", code: "CANCELLED", record_id: run.target_id,
            correlation_ref: run.id, origin: "ui", changed_fields: [], created_at: Time.current }
          if AuditEvent.column_names.include?("proposed_by_actor_ref")
            attrs[:proposed_by_actor_ref] = run.proposed_by_actor_ref.presence || run.actor_ref
          end
          AuditEvent.create!(**attrs)
          sync_from_run!(run, actor_ref: context.actor_ref)
        end
      end

      def append_event!(task, actor_ref:, event_type:, message:, code: nil)
        TaskEvent.create!(
          task_id: task.id,
          actor_ref: actor_ref.to_s.truncate(150),
          event_type: event_type.to_s.truncate(40),
          code: code&.to_s&.truncate(64),
          message: message.to_s.gsub(/[[:cntrl:]]/, " ").squish.truncate(300),
          created_at: Time.current
        )
      end

      # Rendered on every admin page: counts at most BADGE_CAP approvable tasks.
      BADGE_CAP = 10

      def pending_approval_count(context)
        return 0 unless authorized?(context)
        list(context: context, tab: "needs_approval", limit: BADGE_CAP).size
      rescue AccessDenied
        0
      end

      # Each tab is narrowed in SQL first; only the remaining candidates are
      # authorized one by one, and scanning stops once `limit` are found.
      def list(context:, tab: "needs_approval", resource_key: nil, kind: nil, limit: 50)
        raise AccessDenied unless authorized?(context)
        now = Time.current
        tasks = AdminTask.arel_table
        scope = AdminTask.where(tenant_ref: context.tenant_ref)
        scope = scope.where(resource_key: resource_key.to_s) if resource_key.present?
        scope = scope.where(kind: kind.to_s) if kind.present? && KINDS.include?(kind.to_s)
        pending = scope.where(status: "awaiting_approval").where(tasks[:expires_at].gt(now))
        lapsed = scope.where(status: "awaiting_approval").where(tasks[:expires_at].lteq(now))
        scope = case tab.to_s
        when "needs_approval" then pending
        when "active" then scope.where(status: %w[open executing verifying]).or(pending)
        when "completed" then scope.where(status: %w[succeeded partially_failed failed cancelled expired]).or(lapsed)
        when "mine" then scope.where(created_by_actor_ref: context.actor_ref)
        else scope
        end
        ActiveRecord::Base.while_preventing_writes do
          scope.order(updated_at: :desc, id: :desc).limit(200).to_a.lazy.select do |task|
            tab.to_s == "needs_approval" ? can_approve?(context, task) : visible_to?(context, task)
          end.first(limit)
        end
      end

      def find_visible!(context:, id:)
        raise AccessDenied unless authorized?(context) && id.is_a?(String) && id.match?(/\A[0-9a-f-]{36}\z/)
        task = AdminTask.find_by(id: id, tenant_ref: context.tenant_ref)
        raise AccessDenied unless task
        allowed = ActiveRecord::Base.while_preventing_writes { visible_to?(context, task) }
        raise AccessDenied unless allowed
        task
      end

      def can_approve?(context, task)
        return false unless task.operation_run_id && effective_status(task) == "awaiting_approval"
        ActiveRecord::Base.while_preventing_writes do
          run = OperationRun.find_by(id: task.operation_run_id, tenant_ref: context.tenant_ref)
          return false unless run && run.status == "proposed" && run.expires_at && run.expires_at > Time.current
          resource = fetch_resource(task.resource_key)
          return false unless resource
          mode = OperationRun.column_names.include?("approval_mode") ? run.approval_mode.to_s : "self"
          proposer = (OperationRun.column_names.include?("proposed_by_actor_ref") && run.proposed_by_actor_ref.presence) || run.actor_ref
          return false if mode == "separate_actor" && context.actor_ref == proposer
          return false if mode == "self" && context.actor_ref != run.actor_ref
          access = Authorization::Access.new(context, resource)
          record = run.target_id ? access.find!(run.target_id, action: run.operation) : nil
          access.authorize_approval!(run.operation, record, proposed_by_actor_ref: proposer) if mode != "self"
          access.authorize!(run.operation, record)
          true
        rescue AccessDenied
          false
        end
      end

      def can_undo?(context, task)
        return false unless task.operation_run_id && task.status == "succeeded"
        return false if (task.summary_metadata || {}).key?("undone_by_run_id")
        ActiveRecord::Base.while_preventing_writes do
          run = OperationRun.find_by(id: task.operation_run_id, tenant_ref: context.tenant_ref, status: "succeeded")
          return false unless run && run.selection_id.nil? && run.parent_run_id.nil?
          return false unless OperationRun.column_names.include?("undo_payload") && run.undo_payload.is_a?(Hash) && run.undo_payload.any?
          return false if OperationRun.where(compensates_run_id: run.id, status: %w[running succeeded]).exists?
          resource = fetch_resource(run.resource_key)
          return false unless resource
          definition = RailsAiAdmin.operation_registry.fetch(resource, run.operation)
          eligible = definition.custom? ? definition.handler_class.reversible? : resource.undoable?(run.operation)
          return false unless eligible
          access = Authorization::Access.new(context, resource)
          record = run.operation == "destroy" && resource.soft_delete? ? access.discarded_relation.find_by(resource.model_class.primary_key => run.record_id) : access.find!(run.record_id)
          return false unless record && RecordVersion.of(record) == run.post_version
          access.authorize_undo!(run.operation, record)
          true
        rescue AccessDenied
          false
        end
      end

      def visible_to?(context, task)
        return false unless task.tenant_ref == context.tenant_ref
        resource = fetch_resource(task.resource_key)
        return false unless resource
        access = Authorization::Access.new(context, resource)
        if task.created_by_actor_ref == context.actor_ref
          access.authorize!(:index)
          return true
        end
        return true if can_approve?(context, task)
        return false unless task.operation.present?
        access.authorize_receipt!(task.operation, nil)
        true
      rescue AccessDenied
        false
      end

      def derive_run_status(run)
        case run.status
        when "proposed"
          run.expires_at && run.expires_at <= Time.current ? "expired" : "awaiting_approval"
        when "queued", "running"
          "executing"
        when "succeeded"
          "succeeded"
        when "partially_succeeded"
          "partially_failed"
        when "failed", "reconciliation_required"
          "failed"
        when "cancelled"
          "cancelled"
        else
          "open"
        end
      end

      def build_metadata(run, mode:)
        meta = { "approval_mode" => mode }
        if OperationRun.column_names.include?("verification_status") && run.verification_status.present?
          meta["verification_status"] = run.verification_status
        end
        if run.selection_id.present?
          counts = BatchItem.where(parent_run_id: run.id).group(:status).count
          total = counts.values.sum
          total = Array(run.manifest_payload).size if total.zero?
          meta["total_count"] = total
          meta["succeeded_count"] = counts.fetch("succeeded", 0)
          meta["failed_count"] = counts.fetch("failed", 0)
        else
          meta["total_count"] = 1
          meta["succeeded_count"] = run.status == "succeeded" ? 1 : 0
          meta["failed_count"] = run.status == "failed" ? 1 : 0
        end
        meta
      end

      def build_title(run)
        resource = fetch_resource(run.resource_key)
        resource_label = resource ? resource.label : run.resource_key.to_s.humanize
        op_label = if resource
          begin
            RailsAiAdmin.operation_registry.fetch(resource, run.operation).description
          rescue AccessDenied
            run.operation.to_s.humanize
          end
        else
          run.operation.to_s.humanize
        end
        if run.selection_id.present?
          count = Array(run.manifest_payload).size
          "#{op_label} (#{count} #{resource_label.downcase})".truncate(160)
        elsif run.target_id.present?
          "#{op_label} — #{resource_label.singularize} ##{run.target_id}".truncate(160)
        else
          "#{op_label} — #{resource_label}".truncate(160)
        end
      end

      def event_message_for(status, run)
        case status
        when "awaiting_approval" then "Awaiting approval for #{run.operation}"
        when "executing" then "Admitted for execution"
        when "succeeded" then "Completed successfully"
        when "partially_failed" then "Completed with partial failures"
        when "failed" then "Execution failed"
        when "cancelled" then "Cancelled"
        when "expired" then "Approval window expired"
        else "Task updated (#{status})"
        end
      end

      def fetch_resource(key)
        return nil if key.blank?
        RailsAiAdmin.registry.fetch(key)
      rescue ConfigurationError, KeyError, AccessDenied
        nil
      end
    end
  end
end
