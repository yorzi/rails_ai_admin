# frozen_string_literal: true

class CreateRailsAiAdminWorkItems < ActiveRecord::Migration[8.0]
  def change
    create_table :rails_ai_admin_work_items, id: :string, limit: 36 do |t|
      t.string :operation_run_id, null: false, limit: 36
      t.string :work_key, :kind, :handler_version, :payload_digest, null: false
      t.json :payload, null: false, default: {}
      t.string :status, null: false, default: "pending"
      t.bigint :expected_version
      t.integer :generation, :attempts, null: false, default: 0
      t.integer :effect_generation
      t.string :effect_digest, limit: 64
      t.string :lease_owner, limit: 36
      t.datetime :lease_expires_at, :next_attempt_at, :effect_started_at, :completed_at
      t.datetime :deadline_at, null: false
      t.string :last_code
      t.timestamps
    end
    add_index :rails_ai_admin_work_items, [ :operation_run_id, :work_key ], unique: true, name: "raa_work_intent_key"
    add_index :rails_ai_admin_work_items, [ :status, :next_attempt_at ], name: "raa_work_pending"
    add_index :rails_ai_admin_work_items, [ :status, :lease_expires_at ], name: "raa_work_lease"
    add_foreign_key :rails_ai_admin_work_items, :rails_ai_admin_operation_runs, column: :operation_run_id
    add_check_constraint :rails_ai_admin_work_items, "status IN ('pending', 'running', 'succeeded', 'failed', 'cancelled', 'reconciliation_required')", name: "raa_work_status"
  end
end
