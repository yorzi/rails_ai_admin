# frozen_string_literal: true

require_relative "application_record"

module RailsAiAdmin
  # Append-only audit timeline entry for an AdminTask state transition.
  class TaskEvent < ApplicationRecord
    self.table_name = "rails_ai_admin_task_events"
    belongs_to :task, class_name: "RailsAiAdmin::AdminTask", inverse_of: :events
  end
end
