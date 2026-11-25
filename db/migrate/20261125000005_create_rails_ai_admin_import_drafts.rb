# frozen_string_literal: true

class CreateRailsAiAdminImportDrafts < ActiveRecord::Migration[8.0]
  def change
    create_table :rails_ai_admin_import_drafts, id: :string, limit: 36 do |t|
      t.string :tenant_ref, :actor_ref, :resource_key, :security_version, null: false, limit: 150
      t.string :resource_signature, null: false, limit: 64
      t.string :filename, null: false, limit: 160
      t.integer :row_count, null: false
      t.text :payload_blob
      t.json :mapping, :excluded, null: false
      t.string :match_field, limit: 100
      t.string :duplicates, null: false, default: "skip"
      t.string :status, null: false, default: "draft"
      t.string :confirmed_digest, limit: 64
      t.integer :created_count
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :rails_ai_admin_import_drafts, [ :tenant_ref, :actor_ref, :resource_key, :created_at ], name: "raa_import_drafts_owner"
    add_index :rails_ai_admin_import_drafts, :expires_at
    add_check_constraint :rails_ai_admin_import_drafts, "status IN ('draft', 'admitted')", name: "raa_import_draft_status"
  end
end
