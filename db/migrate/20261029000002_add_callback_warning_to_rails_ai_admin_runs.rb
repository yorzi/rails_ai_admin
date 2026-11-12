# frozen_string_literal: true

class AddCallbackWarningToRailsAiAdminRuns < ActiveRecord::Migration[8.0]
  def change
    add_column :rails_ai_admin_operation_runs, :warning_code, :string
  end
end
