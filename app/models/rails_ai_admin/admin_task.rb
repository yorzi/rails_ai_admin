# frozen_string_literal: true

require_relative "application_record"

module RailsAiAdmin
  # Thin durable coordination and inbox wrapper over OperationRun, Selection and Chat.
  class AdminTask < ApplicationRecord
    self.table_name = "rails_ai_admin_tasks"
    has_many :events, -> { order(:created_at, :id) }, class_name: "RailsAiAdmin::TaskEvent",
      foreign_key: :task_id, inverse_of: :task, dependent: :delete_all
  end
end
