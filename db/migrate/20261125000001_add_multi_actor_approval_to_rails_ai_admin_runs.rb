# frozen_string_literal: true

class AddMultiActorApprovalToRailsAiAdminRuns < ActiveRecord::Migration[8.0]
  def change
    change_table :rails_ai_admin_operation_runs do |t|
      t.string :proposed_by_actor_ref, limit: 150
      t.string :approval_mode, null: false, default: "self", limit: 32
      t.string :approver_security_version, limit: 150
      t.string :approval_note, limit: 500
    end
    add_index :rails_ai_admin_operation_runs, [ :tenant_ref, :approval_mode, :status, :expires_at ], name: "raa_runs_pending_approvals"
    add_check_constraint :rails_ai_admin_operation_runs, "approval_mode IN ('self', 'separate_actor', 'any_reviewer')", name: "raa_runs_approval_mode"

    add_column :rails_ai_admin_audit_events, :proposed_by_actor_ref, :string, limit: 150
  end
end
