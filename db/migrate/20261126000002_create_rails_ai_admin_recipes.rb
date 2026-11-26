# frozen_string_literal: true

class CreateRailsAiAdminRecipes < ActiveRecord::Migration[8.0]
  def change
    create_table :rails_ai_admin_recipes, id: :string, limit: 36 do |t|
      t.string :tenant_ref, :owner_ref, :owner_epoch, :principal_ref, :principal_epoch, null: false, limit: 150
      t.string :slug, :resource_key, null: false, limit: 64
      t.string :name, null: false, limit: 80
      t.integer :version, null: false, default: 1
      t.text :instructions, null: false
      t.json :plan, null: false
      t.string :trigger_kind, null: false, default: "manual"
      t.string :schedule_cron, :time_zone, limit: 64
      t.string :event_name, limit: 100
      t.string :overlap_policy, null: false, default: "skip"
      t.integer :max_runs_per_day, null: false, default: 24
      t.boolean :enabled, null: false, default: false
      t.datetime :next_run_at, :paused_at
      t.string :pause_reason
      t.timestamps
    end
    add_index :rails_ai_admin_recipes, [ :tenant_ref, :slug ], unique: true, name: "raa_recipe_slug"
    add_index :rails_ai_admin_recipes, [ :enabled, :next_run_at ], name: "raa_recipe_schedule"
    add_index :rails_ai_admin_recipes, [ :tenant_ref, :event_name, :enabled ], name: "raa_recipe_events"
    add_check_constraint :rails_ai_admin_recipes, "trigger_kind IN ('manual','schedule','event') AND overlap_policy IN ('skip','queue_one') AND max_runs_per_day BETWEEN 1 AND 100", name: "raa_recipe_bounds"

    # Use the same key type as the optional polymorphic RubyLLM usage owner.
    key = table_exists?(:ruby_llm_usages) && connection.columns(:ruby_llm_usages).find { |c| c.name == "owner_id" }&.type == :uuid ? :uuid : :bigint
    create_table :rails_ai_admin_recipe_runs, id: key do |t|
      t.string :recipe_id, null: false, limit: 36
      t.integer :recipe_version, null: false
      t.string :tenant_ref, :principal_ref, null: false, limit: 150
      t.string :trigger_kind, :status, null: false
      t.string :dedup_key, null: false, limit: 128
      t.string :target_id, :budget_slot, limit: 150
      t.string :task_id, limit: 36
      t.json :definition, null: false
      t.string :error_code, limit: 64
      t.datetime :started_at, :completed_at
      t.timestamps
    end
    add_foreign_key :rails_ai_admin_recipe_runs, :rails_ai_admin_recipes, column: :recipe_id
    add_index :rails_ai_admin_recipe_runs, [ :recipe_id, :dedup_key ], unique: true, name: "raa_recipe_occurrence"
    add_index :rails_ai_admin_recipe_runs, [ :recipe_id, :created_at ], name: "raa_recipe_history"
    add_index :rails_ai_admin_recipe_runs, [ :status, :created_at ], name: "raa_recipe_pending"
    add_index :rails_ai_admin_recipe_runs, :budget_slot, unique: true, where: "budget_slot IS NOT NULL", name: "raa_recipe_provider_slot"
  end
end
