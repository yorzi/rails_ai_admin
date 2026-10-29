# frozen_string_literal: true

module RailsAiAdmin
  # Durable server-issued intent and atomic receipt; not a public write API.
  class OperationRun < ApplicationRecord
    self.table_name = "rails_ai_admin_operation_runs"
  end
end
