# frozen_string_literal: true

class CreateRailsAiAdminCollectionRuns < ActiveRecord::Migration[8.0]
  def change
    remove_check_constraint :rails_ai_admin_operation_runs, "status IN ('proposed', 'running', 'succeeded')", name: "raa_runs_status"
    change_table :rails_ai_admin_operation_runs do |t|
      t.string :selection_id, :parent_run_id, limit: 36
      t.string :selection_digest, :manifest_resource_version, limit: 64
      t.json :input_payload, :manifest_payload
      t.datetime :execution_deadline, :cancellation_requested_at
    end
    add_foreign_key :rails_ai_admin_operation_runs, :rails_ai_admin_selections, column: :selection_id
    add_foreign_key :rails_ai_admin_operation_runs, :rails_ai_admin_operation_runs, column: :parent_run_id
    add_index :rails_ai_admin_operation_runs, [ :parent_run_id, :target_id ], unique: true, name: "raa_child_target"
    add_check_constraint :rails_ai_admin_operation_runs,
      "status IN ('proposed', 'queued', 'running', 'succeeded', 'failed', 'partially_succeeded', 'cancelled', 'reconciliation_required')", name: "raa_runs_status"

    create_table :rails_ai_admin_batch_items, id: :string, limit: 36 do |t|
      t.string :parent_run_id, :operation_run_id, null: false, limit: 36
      t.bigint :selection_item_id, null: false
      t.string :target_id, null: false, limit: 150
      t.bigint :expected_version, null: false
      t.integer :position, null: false
      t.string :status, null: false, default: "queued"
      t.string :lease_owner, limit: 36
      t.integer :generation, :attempts, null: false, default: 0
      t.string :last_code, limit: 64
      t.datetime :lease_expires_at, :next_attempt_at, :completed_at
      t.timestamps
    end
    add_foreign_key :rails_ai_admin_batch_items, :rails_ai_admin_operation_runs, column: :parent_run_id
    add_foreign_key :rails_ai_admin_batch_items, :rails_ai_admin_operation_runs, column: :operation_run_id
    add_foreign_key :rails_ai_admin_batch_items, :rails_ai_admin_selection_items, column: :selection_item_id
    add_index :rails_ai_admin_batch_items, :operation_run_id, unique: true, name: "raa_batch_child"
    add_index :rails_ai_admin_batch_items, [ :parent_run_id, :target_id ], unique: true, name: "raa_batch_target"
    add_index :rails_ai_admin_batch_items, [ :parent_run_id, :position ], unique: true, name: "raa_batch_order"
    add_index :rails_ai_admin_batch_items, [ :status, :lease_expires_at, :next_attempt_at ], name: "raa_batch_due"
    add_check_constraint :rails_ai_admin_batch_items, "status IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')", name: "raa_batch_status"
    add_check_constraint :rails_ai_admin_batch_items, "position BETWEEN 0 AND 99 AND expected_version >= 0 AND generation >= 0 AND attempts >= 0", name: "raa_batch_bounds"
  end
end
