# frozen_string_literal: true

class CreateRailsAiAdminImportRows < ActiveRecord::Migration[8.0]
  def change
    add_column :rails_ai_admin_import_drafts, :execution_zone, :string, limit: 64
    create_table :rails_ai_admin_import_rows do |t|
      t.string :draft_id, null: false, limit: 36
      t.integer :number, null: false
      t.text :input_blob
      t.string :status, null: false, default: "queued"
      t.string :error_code, limit: 64
      t.integer :attempts, null: false, default: 0
      t.timestamps
    end
    add_foreign_key :rails_ai_admin_import_rows, :rails_ai_admin_import_drafts, column: :draft_id, on_delete: :cascade
    add_index :rails_ai_admin_import_rows, [ :draft_id, :number ], unique: true, name: "raa_import_row_number"
    add_index :rails_ai_admin_import_rows, [ :status, :draft_id ], name: "raa_import_row_pending"
    add_check_constraint :rails_ai_admin_import_rows, "status IN ('queued','created','skipped','failed')", name: "raa_import_row_status"
  end
end
