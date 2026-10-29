# frozen_string_literal: true

module RailsAiAdmin
  class WorkItem < ApplicationRecord
    self.table_name = "rails_ai_admin_work_items"
    after_create_commit :dispatch_after_commit

    private

    def dispatch_after_commit
      Outbox::DeliveryJob.perform_later(id) if RailsAiAdmin.configuration.outbox_auto_dispatch
    rescue StandardError
      # The durable pending row survives a queue outage or process loss. A host
      # must schedule scan_pending! even when after-commit acceleration is enabled.
      nil
    end
  end
end
