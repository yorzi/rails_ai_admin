# frozen_string_literal: true

class CreateRailsAiAdminExecutionTables < ActiveRecord::Migration[8.1]
  def change
    create_table :rails_ai_admin_operation_runs, id: :string, limit: 36 do |t|
      t.string :actor_ref, :tenant_ref, :security_version, null: false, limit: 150
      t.string :resource_key, :operation, :operation_version, null: false
      t.string :target_id, :record_id, limit: 150
      t.bigint :expected_version
      t.string :input_digest, :approved_digest, limit: 64
      t.string :status, null: false, default: "proposed"
      t.string :origin, null: false, default: "ui"
      t.string :approved_by_ref, limit: 150
      t.datetime :confirmed_at, :expires_at, :completed_at
      t.bigint :audit_event_id
      t.timestamps
    end
    add_index :rails_ai_admin_operation_runs, [ :tenant_ref, :actor_ref, :created_at ], name: "raa_runs_owner"
    add_index :rails_ai_admin_operation_runs, [ :status, :expires_at ], name: "raa_runs_expiry"
    add_check_constraint :rails_ai_admin_operation_runs, "status IN ('proposed', 'running', 'succeeded')", name: "raa_runs_status"

    create_table :rails_ai_admin_audit_events do |t|
      t.string :actor_ref, :tenant_ref, null: false, limit: 150
      t.string :resource_key, :operation, :status, :code, null: false
      t.string :record_id, limit: 150
      t.string :correlation_ref, null: false, limit: 36
      t.string :origin, null: false
      t.json :changed_fields, null: false, default: []
      t.datetime :created_at, null: false
    end
    add_index :rails_ai_admin_audit_events, [ :tenant_ref, :created_at ], name: "raa_audit_tenant"
    add_index :rails_ai_admin_audit_events, :correlation_ref, name: "raa_audit_correlation"
    add_foreign_key :rails_ai_admin_operation_runs, :rails_ai_admin_audit_events, column: :audit_event_id
  end
end
