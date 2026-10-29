# frozen_string_literal: true

class CreateRailsAiAdminSelections < ActiveRecord::Migration[8.1]
  def change
    create_table :rails_ai_admin_selections, id: :string, limit: 36 do |t|
      t.string :actor_ref, :tenant_ref, :security_version, null: false, limit: 150
      t.string :resource_key, null: false
      t.string :resource_version, :manifest_digest, null: false, limit: 64
      t.integer :item_count, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :rails_ai_admin_selections, [ :tenant_ref, :actor_ref, :created_at ], name: "raa_selections_owner"
    add_index :rails_ai_admin_selections, :expires_at, name: "raa_selections_expiry"
    add_check_constraint :rails_ai_admin_selections, "item_count BETWEEN 1 AND 100", name: "raa_selections_count"

    create_table :rails_ai_admin_selection_items do |t|
      t.string :selection_id, null: false, limit: 36
      t.string :target_id, null: false, limit: 150
      t.bigint :expected_version, null: false
      t.integer :position, null: false
    end
    add_foreign_key :rails_ai_admin_selection_items, :rails_ai_admin_selections, column: :selection_id
    add_index :rails_ai_admin_selection_items, [ :selection_id, :target_id ], unique: true, name: "raa_selection_targets"
    add_index :rails_ai_admin_selection_items, [ :selection_id, :position ], unique: true, name: "raa_selection_order"
    add_check_constraint :rails_ai_admin_selection_items, "expected_version >= 0 AND position BETWEEN 0 AND 99", name: "raa_selection_item_bounds"
  end
end
