# frozen_string_literal: true

class AddMissingIndexesToRailsAiAdminTables < ActiveRecord::Migration[8.1]
  def change
    add_index :rails_ai_admin_batch_items, :selection_item_id, name: "raa_batch_selection_item"
    add_index :rails_ai_admin_batch_items, [ :status, :next_attempt_at ], name: "raa_batch_queued"
    add_index :rails_ai_admin_operation_runs, :selection_id, name: "raa_runs_selection"
    add_index :rails_ai_admin_operation_runs, :audit_event_id, name: "raa_runs_audit_event"
    add_index :rails_ai_admin_work_items, [ :status, :deadline_at ], name: "raa_work_deadline"
    add_index :rails_ai_admin_audit_events, [ :tenant_ref, :resource_key, :id ], name: "raa_audit_tenant_resource_id"
  end
end
