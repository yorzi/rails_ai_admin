# frozen_string_literal: true

module RailsAiAdmin
  module Recipes
    class ExecutionJob < ActiveJob::Base
      queue_as { RailsAiAdmin.configuration.queue_name }

      def perform(run_id)
        Execution.call(run_id)
      end
    end
  end
end
