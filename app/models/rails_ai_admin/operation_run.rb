# frozen_string_literal: true

module RailsAiAdmin
  # Durable server-issued intent and atomic receipt; not a public write API.
  class OperationRun < ApplicationRecord
    self.table_name = "rails_ai_admin_operation_runs"
    after_update_commit :dispatch_collection

    private

    def dispatch_collection
      if selection_id && status == "queued" && saved_change_to_status? && RailsAiAdmin.configuration.collection_auto_dispatch
        Collections::ExecutionJob.perform_later(id)
      end
    rescue StandardError
      # A scheduled pending scan must recover a lost enqueue.
      nil
    end
  end
end
