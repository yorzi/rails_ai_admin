# frozen_string_literal: true

module RailsAiAdmin
  module Collections
    class Queries
      Entry = Data.define(:record_id, :label, :status, :code, :audit_ref, :warning, :work_statuses)
      # waiting_since: when the oldest still-queued item of an active run was
      # queued, so a page can say that nothing has picked it up (RAA-020).
      Snapshot = Data.define(:job_ref, :resource_key, :operation, :description, :status, :counts, :entries, :hidden_count, :can_cancel, :warning, :waiting_since)

      def fetch(context:, job_ref:, summary: false)
        ActiveRecord::Base.while_preventing_writes do
          parent = Contract.owned(context, job_ref)
          resource, definition = Contract.definition(parent)
          access = Authorization::Access.new(context, resource)
          access.authorize_receipt!(parent.operation, nil)
          Contract.verify_manifest!(parent)
          Contract.verify_approved!(parent, definition, context) if parent.approved_digest
          items = BatchItem.where(parent_run_id: parent.id).order(:position).limit(Selections::Builder::LIMIT + 1).to_a
          if parent.approved_digest && items.size != parent.manifest_payload.size
            raise ConfigurationError, "Collection result manifest is inconsistent"
          end
          counts = items.group_by(&:status).transform_values(&:size).freeze
          entries = summary ? [] : items.filter_map { |item| entry(access, parent, item) }
          cancellable = begin
            access.authorize_cancel!(parent.operation)
            parent.status == "proposed" || Contract::ACTIVE.include?(parent.status)
          rescue AccessDenied
            false
          end
          waiting = Contract::ACTIVE.include?(parent.status) && items.none? { |item| item.status == "running" } ?
            items.select { |item| item.status == "queued" }.map(&:created_at).compact.min : nil
          Snapshot.new(parent.id, resource.key.to_s, parent.operation, definition.description, parent.status, counts,
            entries.freeze, summary ? 0 : items.size - entries.size, cancellable, parent.warning_code, waiting)
        end
      rescue StandardError => error
        raise if error.is_a?(AccessDenied) || error.is_a?(ConfigurationError)
        raise ConfigurationError, "Collection result cannot be projected safely", cause: nil
      end

      def recent(context:)
        raise AccessDenied, "UNAUTHENTICATED" unless context.is_a?(Context)
        refs = OperationRun.where(actor_ref: context.actor_ref, tenant_ref: context.tenant_ref, security_version: context.security_version,
          parent_run_id: nil).where.not(selection_id: nil).where.not(status: "proposed").order(created_at: :desc, id: :desc).limit(50).pluck(:id)
        refs.filter_map do |ref|
          fetch(context: context, job_ref: ref, summary: true)
        rescue AccessDenied
          nil
        end
      end

      private

      def entry(access, parent, item)
        unless parent.manifest_payload[item.position] == [ item.target_id, item.expected_version ]
          raise ConfigurationError, "Collection item identity changed"
        end
        record = access.find!(item.target_id)
        access.authorize_receipt!(parent.operation, record)
        label = access.record_label(record)
        child = OperationRun.find_by!(id: item.operation_run_id, parent_run_id: parent.id)
        unless child.target_id == item.target_id && child.expected_version == item.expected_version &&
            child.resource_key == parent.resource_key && child.operation == parent.operation && child.input_digest == parent.input_digest &&
            child.actor_ref == parent.actor_ref && child.tenant_ref == parent.tenant_ref && child.operation_version == parent.operation_version
          raise ConfigurationError, "Collection child identity changed"
        end
        work = WorkItem.where(operation_run_id: child.id).filter_map do |work_item|
          access.authorize_delivery!(parent.operation, work_item.kind, record)
          work_item.status
        rescue AccessDenied
          nil
        end.tally.freeze
        Entry.new(record.id.to_s, label, item.status, item.last_code, child.audit_event_id, child.warning_code, work)
      rescue AccessDenied
        nil
      end
    end
  end
end
