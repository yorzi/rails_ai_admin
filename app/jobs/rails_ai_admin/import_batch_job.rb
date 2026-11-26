# frozen_string_literal: true

module RailsAiAdmin
  class ImportBatchJob < ActiveJob::Base
    queue_as { RailsAiAdmin.configuration.queue_name }

    def perform(id)
      self.class.perform_later(id) if Presentation::ImportBatch.process(id)
    end
  end
end
