# frozen_string_literal: true

module RailsAiAdmin
  # Runs due assistant turns of one chat. Loading this file loads no RubyLLM
  # code; the assistant is required only when a job actually runs.
  class AssistantTurnJob < ActiveJob::Base
    queue_as :rails_ai_admin

    def perform(chat_ref)
      return unless RailsAiAdmin.configuration.assistant
      require "rails_ai_admin/assistant"
      Assistant::Coordinator.new.run(chat_ref)
    end
  end
end
