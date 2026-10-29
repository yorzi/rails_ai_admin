# frozen_string_literal: true

module RailsAiAdmin
  # Only exact canonical identity and optimistic version are retained.
  class SelectionItem < ApplicationRecord
    self.table_name = "rails_ai_admin_selection_items"
    def readonly? = persisted?
  end
end
