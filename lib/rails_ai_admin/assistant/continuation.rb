# frozen_string_literal: true

module RailsAiAdmin
  module Assistant
    # Admits the human's Surface outcome into its chat as one continuation turn.
    # It runs inside the Surface confirmation transaction, so the business
    # write, audit, receipt, Surface revision and this admission commit or roll
    # back together, and the intent key admits it at most once.
    module Continuation
      CHAT_REFERENCE = /\Araa:chat:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z/

      module_function

      def chat_reference?(value) = value.is_a?(String) && value.match?(CHAT_REFERENCE)

      def admit!(context:, context_ref:, review:, outcome:, decision: "confirmed")
        match = context_ref.is_a?(String) && context_ref.match(CHAT_REFERENCE)
        return unless match
        chat = Chat.owned(context, match[1])
        return unless chat&.current_for?(context)
        Coordinator.admit!(chat, kind: "continuation", content: content(review, outcome, decision), admission_key: "intent:#{review.run.id}")
      end

      # Server-written summary of the committed outcome; no Surface input text.
      def content(review, outcome, decision = "confirmed")
        subject = "#{review.resource.label.singularize} \"#{review.access.record_label(review.record)}\""
        action = review.definition.description.to_s.truncate(120)
        verb = decision == "dismissed" ? "dismissed" : "confirmed"
        "Review result: the user #{verb} \"#{action}\" for #{subject}. #{outcome}"
      end
    end
  end
end
