# frozen_string_literal: true

class WidenRailsAiAdminBulkBounds < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    with_table_rebuild_safety do
      remove_check_constraint :rails_ai_admin_selections, "item_count BETWEEN 1 AND 100", name: "raa_selections_count"
      add_check_constraint :rails_ai_admin_selections, "item_count BETWEEN 1 AND 10000", name: "raa_selections_count"

      remove_check_constraint :rails_ai_admin_selection_items, "expected_version >= 0 AND position BETWEEN 0 AND 99", name: "raa_selection_item_bounds"
      add_check_constraint :rails_ai_admin_selection_items, "expected_version >= 0 AND position BETWEEN 0 AND 9999", name: "raa_selection_item_bounds"

      remove_check_constraint :rails_ai_admin_batch_items,
        "position BETWEEN 0 AND 99 AND expected_version >= 0 AND generation >= 0 AND attempts >= 0", name: "raa_batch_bounds"
      add_check_constraint :rails_ai_admin_batch_items,
        "position BETWEEN 0 AND 9999 AND expected_version >= 0 AND generation >= 0 AND attempts >= 0", name: "raa_batch_bounds"
    end

    unless column_exists?(:rails_ai_admin_operation_runs, :retry_of_run_id)
      add_column :rails_ai_admin_operation_runs, :retry_of_run_id, :string, limit: 36
      add_foreign_key :rails_ai_admin_operation_runs, :rails_ai_admin_operation_runs, column: :retry_of_run_id, on_delete: :nullify
      add_index :rails_ai_admin_operation_runs, :retry_of_run_id, name: "raa_runs_retry_of"
    end
  end

  def down
    if column_exists?(:rails_ai_admin_operation_runs, :retry_of_run_id)
      remove_index :rails_ai_admin_operation_runs, name: "raa_runs_retry_of"
      remove_foreign_key :rails_ai_admin_operation_runs, column: :retry_of_run_id
      remove_column :rails_ai_admin_operation_runs, :retry_of_run_id
    end

    with_table_rebuild_safety do
      remove_check_constraint :rails_ai_admin_batch_items,
        "position BETWEEN 0 AND 9999 AND expected_version >= 0 AND generation >= 0 AND attempts >= 0", name: "raa_batch_bounds"
      add_check_constraint :rails_ai_admin_batch_items,
        "position BETWEEN 0 AND 99 AND expected_version >= 0 AND generation >= 0 AND attempts >= 0", name: "raa_batch_bounds"

      remove_check_constraint :rails_ai_admin_selection_items, "expected_version >= 0 AND position BETWEEN 0 AND 9999", name: "raa_selection_item_bounds"
      add_check_constraint :rails_ai_admin_selection_items, "expected_version >= 0 AND position BETWEEN 0 AND 99", name: "raa_selection_item_bounds"

      remove_check_constraint :rails_ai_admin_selections, "item_count BETWEEN 1 AND 10000", name: "raa_selections_count"
      add_check_constraint :rails_ai_admin_selections, "item_count BETWEEN 1 AND 100", name: "raa_selections_count"
    end
  end

  private

  def with_table_rebuild_safety(&block)
    if connection.adapter_name == "SQLite"
      disable_referential_integrity(&block)
    else
      yield
    end
  end
end
