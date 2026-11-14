# frozen_string_literal: true

class CreateRailsAiAdminSavedViews < ActiveRecord::Migration[8.0]
  def change
    create_table :rails_ai_admin_saved_views do |t|
      t.string :actor_ref, :tenant_ref, null: false, limit: 150
      t.string :resource_key, null: false, limit: 100
      t.string :name, null: false, limit: 80
      # The canonical list hint as JSON; never a grant or a query.
      t.text :state, null: false
      t.timestamps
    end
    add_index :rails_ai_admin_saved_views, [ :tenant_ref, :actor_ref, :resource_key, :name ], unique: true, name: "raa_saved_views_owner_name"
  end
end
