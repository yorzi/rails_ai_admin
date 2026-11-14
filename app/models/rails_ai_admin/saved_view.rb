# frozen_string_literal: true

module RailsAiAdmin
  # A person's named list settings for one resource. The stored state is a
  # list hint: it is normalized under current grants every time it is shown.
  class SavedView < ApplicationRecord
    self.table_name = "rails_ai_admin_saved_views"
  end
end
