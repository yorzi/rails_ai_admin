# frozen_string_literal: true

# Serves a record's history page: one tenant, resource and record, newest first.
class AddRecordIndexToRailsAiAdminAuditEvents < ActiveRecord::Migration[8.0]
  def change
    add_index :rails_ai_admin_audit_events, [ :tenant_ref, :resource_key, :record_id, :id ], name: "raa_audit_record"
  end
end
