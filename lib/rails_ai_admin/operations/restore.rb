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
        raise ConfigurationError, "Unsupported origin" unless Runner::ORIGINS.include?(origin.to_s)
        raise AccessDenied unless resource.soft_delete? && resource.action_enabled?(:restore)
        raise AccessDenied, "INVALID_QUERY" unless expected_version.is_a?(String) && expected_version.valid_encoding? && expected_version.match?(/\A(?:0|[1-9]\d{0,18})\z/) && Integer(expected_version, 10) <= 2**63 - 1
        access = Authorization::Access.new(context, resource)
        raise AccessDenied unless access.canonical_id?(id)
        model = resource.model_class
        ensure_connection!(model)
        OperationRun.transaction(requires_new: true) do
          record = model.unscoped.lock.find_by(model.primary_key => id)
          raise AccessDenied unless record && access.discarded_relation.where(model.primary_key => record.id).exists?
          access.authorize!(:restore, record)
          raise AccessDenied, "CONFLICT" unless RecordVersion.of(record) == expected_version.to_i
          record.public_send("#{resource.soft_delete}=", nil)
          record.save!
          raise AccessDenied unless access.relation.where(model.primary_key => record.id).exists?
          audit = AuditEvent.create!(actor_ref: context.actor_ref, tenant_ref: context.tenant_ref, resource_key: resource.key.to_s,
            operation: "restore", status: "succeeded", code: "OK", record_id: record.id.to_s, correlation_ref: SecureRandom.uuid,
            origin: origin.to_s, changed_fields: [], created_at: Time.current)
          Result.new(code: "OK", record_id: record.id.to_s, audit_ref: audit.id)
        end
      rescue ActiveRecord::StaleObjectError, ActiveRecord::RecordNotUnique, ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout,
        ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, ActiveRecord::InvalidForeignKey
        raise AccessDenied, "CONFLICT", cause: nil
      rescue ActiveRecord::StatementInvalid => error
        raise unless defined?(SQLite3::BusyException) && error.cause.is_a?(SQLite3::BusyException)
        raise AccessDenied, "CONFLICT", cause: nil
      end

      private

      def ensure_connection!(model)
        unless model.connection_pool.equal?(OperationRun.connection_pool) && model.connection_pool.equal?(AuditEvent.connection_pool)
          raise ConfigurationError, "Domain, intent and audit must use the same connection pool"
        end
        unless RecordVersion.supported?(model)
          raise ConfigurationError, "Writes require lock_version or an updated_at timestamp, and a single primary key"
        end
        unless %w[SQLite PostgreSQL].include?(model.connection.adapter_name)
          raise ConfigurationError, "Only SQLite and PostgreSQL are supported for writes"
        end
      end
    end
  end
end
