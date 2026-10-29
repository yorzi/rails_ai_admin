# frozen_string_literal: true

module RailsAiAdmin
  # Minimal append-only execution evidence. Direct SQL is outside this boundary.
  class AuditEvent < ApplicationRecord
    self.table_name = "rails_ai_admin_audit_events"

    def readonly?
      persisted? || super
    end
  end
end
