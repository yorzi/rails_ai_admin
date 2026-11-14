# frozen_string_literal: true

require "securerandom"

module RailsAiAdmin
  module Operations
    # Brings back one soft-deleted record. It needs the current :restore grant
    # for that record, the version the person saw, a row lock and the record
    # landing back inside the policy relation; it writes one audit event.
    class Restore
      Result = Data.define(:code, :record_id, :audit_ref)

      def call(context:, resource:, id:, expected_version:, origin: :ui)
        raise AccessDenied, "UNAUTHENTICATED" unless context.is_a?(Context)
        raise AccessDenied unless resource.soft_delete? && resource.action_enabled?(:restore)
        raise AccessDenied, "INVALID_QUERY" unless expected_version.is_a?(String) && expected_version.match?(/\A(?:0|[1-9]\d{0,18})\z/)
        access = Authorization::Access.new(context, resource)
        raise AccessDenied unless access.canonical_id?(id)
        model = resource.model_class
        OperationRun.transaction(requires_new: true) do
          record = access.discarded_relation.lock.find_by(model.primary_key => id) || raise(AccessDenied)
          access.authorize!(:restore, record)
          raise AccessDenied, "CONFLICT" unless RecordVersion.of(record) == expected_version.to_i
          record.public_send("#{resource.soft_delete}=", nil)
          record.save!(validate: false)
          raise AccessDenied unless access.relation.where(model.primary_key => record.id).exists?
          audit = AuditEvent.create!(actor_ref: context.actor_ref, tenant_ref: context.tenant_ref, resource_key: resource.key.to_s,
            operation: "restore", status: "succeeded", code: "OK", record_id: record.id.to_s, correlation_ref: SecureRandom.uuid,
            origin: origin.to_s, changed_fields: [], created_at: Time.current)
          Result.new(code: "OK", record_id: record.id.to_s, audit_ref: audit.id)
        end
      rescue ActiveRecord::StaleObjectError, ActiveRecord::RecordNotUnique, ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
        raise AccessDenied, "CONFLICT", cause: nil
      end
    end
  end
end
