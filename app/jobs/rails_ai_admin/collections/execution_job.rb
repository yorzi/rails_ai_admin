# frozen_string_literal: true

module RailsAiAdmin
  module Collections
    class ExecutionJob < ActiveJob::Base
      queue_as :rails_ai_admin
      def perform(job_ref)
        Dispatcher.new.run(job_ref)
      end
    end
  end
end
