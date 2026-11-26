# frozen_string_literal: true

class CreateRailsAiAdminSavedQueries < ActiveRecord::Migration[8.0]
  def change
    create_table :rails_ai_admin_saved_queries, id: :string, limit: 36 do |t|
      t.string :tenant_ref, :actor_ref, :resource_key, null: false, limit: 150
      t.string :name, null: false, limit: 80
      t.json :query_ast, null: false
      t.integer :ast_version, null: false, default: 1
      t.boolean :shared, :pinned, null: false, default: false
      t.timestamps
    end
    add_index :rails_ai_admin_saved_queries, [ :tenant_ref, :actor_ref, :resource_key ], name: "raa_reports_owner"
    add_index :rails_ai_admin_saved_queries, [ :tenant_ref, :shared, :pinned ], name: "raa_reports_overview"
  end
end
