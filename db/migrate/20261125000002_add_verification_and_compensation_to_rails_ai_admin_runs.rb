# frozen_string_literal: true

class AddVerificationAndCompensationToRailsAiAdminRuns < ActiveRecord::Migration[8.0]
  def change
    change_table :rails_ai_admin_operation_runs do |t|
      t.string :verification_status, limit: 32
      t.json :verification_report
      t.string :compensates_run_id, limit: 36
      t.bigint :post_version
      t.json :undo_payload
    end
    add_foreign_key :rails_ai_admin_operation_runs, :rails_ai_admin_operation_runs, column: :compensates_run_id, on_delete: :nullify
    add_index :rails_ai_admin_operation_runs, :compensates_run_id, name: "raa_runs_compensates"
    add_check_constraint :rails_ai_admin_operation_runs,
      "verification_status IS NULL OR verification_status IN ('passed', 'warning', 'failed', 'error')",
      name: "raa_runs_verification_status"
  end
end
