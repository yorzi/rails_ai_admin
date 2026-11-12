# frozen_string_literal: true

module RailsAiAdmin
  module Outbox
    class DeliveryJob < ActiveJob::Base
      queue_as { RailsAiAdmin.configuration.queue_name }

      def perform(work_ref)
        Dispatcher.new.run(work_ref)
      end
    end
  end
end
