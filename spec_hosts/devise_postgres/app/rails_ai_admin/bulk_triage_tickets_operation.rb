class BulkTriageTicketsOperation < RailsAiAdmin::Operation
  description "Review selected tickets"
  lease_duration 5
  execution_window 120
  max_duration 1
  input do
    enum :decision, values: %w[triage close], required: true, nullable: false
    textarea :review_note, max_length: 500
  end
  def preflight(context, ticket, input) = TriageTicketOperation.new.preflight(context, ticket, input)
  def perform(context, ticket, input) = TriageTicketOperation.new.perform(context, ticket, input)
end
