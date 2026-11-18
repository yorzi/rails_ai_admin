# frozen_string_literal: true

class AddBulkChangeDecisionToRailsAiAdminSelections < ActiveRecord::Migration[8.0]
  def change
    add_column :rails_ai_admin_selections, :bulk_change_decision, :string
    add_check_constraint :rails_ai_admin_selections, "bulk_change_decision IN ('confirm', 'dismiss')", name: "raa_bulk_change_decision"
  end
end
