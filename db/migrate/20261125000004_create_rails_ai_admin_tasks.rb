# frozen_string_literal: true

class CreateRailsAiAdminTasks < ActiveRecord::Migration[8.0]
  def change
    create_table :rails_ai_admin_tasks, id: :string, limit: 36 do |t|
      t.string :tenant_ref, null: false, limit: 150
      t.string :created_by_actor_ref, null: false, limit: 150
      t.string :assigned_to_actor_ref, limit: 150
      t.string :kind, null: false, limit: 32
      t.string :status, null: false, limit: 32, default: "open"
      t.string :title, null: false, limit: 160
      t.string :resource_key, limit: 64
      t.string :operation, limit: 80
      t.string :chat_id, limit: 64
      t.string :operation_run_id, limit: 36
      t.string :selection_id, limit: 36
      t.string :surface_id, limit: 64
      t.json :summary_metadata, null: false, default: {}
      t.datetime :expires_at
      t.datetime :completed_at
      t.timestamps
    end

    add_foreign_key :rails_ai_admin_tasks, :rails_ai_admin_operation_runs, column: :operation_run_id, on_delete: :cascade
    add_foreign_key :rails_ai_admin_tasks, :rails_ai_admin_selections, column: :selection_id, on_delete: :nullify

    add_index :rails_ai_admin_tasks, [ :tenant_ref, :status, :updated_at ], name: "raa_tasks_tenant_status"
    add_index :rails_ai_admin_tasks, [ :tenant_ref, :created_by_actor_ref, :updated_at ], name: "raa_tasks_creator"
    add_index :rails_ai_admin_tasks, :operation_run_id, unique: true, name: "raa_tasks_operation_run"
    add_index :rails_ai_admin_tasks, :selection_id, name: "raa_tasks_selection"

    add_check_constraint :rails_ai_admin_tasks,
      "kind IN ('change_review', 'bulk_job', 'quality_remediation', 'import', 'recipe_run')",
      name: "raa_tasks_kind"
    add_check_constraint :rails_ai_admin_tasks,
      "status IN ('open', 'awaiting_approval', 'executing', 'verifying', 'succeeded', 'partially_failed', 'failed', 'cancelled', 'expired')",
      name: "raa_tasks_status"

    create_table :rails_ai_admin_task_events do |t|
      t.string :task_id, null: false, limit: 36
      t.string :actor_ref, null: false, limit: 150
      t.string :event_type, null: false, limit: 40
      t.string :code, limit: 64
      t.string :message, null: false, limit: 300
      t.datetime :created_at, null: false
    end

    add_foreign_key :rails_ai_admin_task_events, :rails_ai_admin_tasks, column: :task_id, on_delete: :cascade
    add_index :rails_ai_admin_task_events, [ :task_id, :created_at, :id ], name: "raa_task_events_timeline"
  end
end
