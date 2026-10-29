# frozen_string_literal: true

module RailsAiAdmin
  # Immutable target snapshot, not approval or execution authority.
  class Selection < ApplicationRecord
    self.table_name = "rails_ai_admin_selections"
    def readonly? = persisted?
  end
end
