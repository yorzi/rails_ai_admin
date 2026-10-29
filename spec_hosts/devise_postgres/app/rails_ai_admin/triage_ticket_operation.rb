class TriageTicketOperation < RailsAiAdmin::Operation
  description "Review and triage ticket"
  input do
    enum :decision, values: %w[triage close], required: true, nullable: false
    textarea :review_note, max_length: 500
  end

  def preflight(_context, _ticket, input)
    { state: input.fetch("decision") == "close" ? "closed" : "triaged", internal_note: input["review_note"] }
  end

  def perform(context, ticket, input)
    ticket.update!(state: input.fetch("decision") == "close" ? "closed" : "triaged", internal_note: input["review_note"])
    kind = input.fetch("decision") == "close" ? "tickets.closed" : "tickets.triaged"
    context.outbox.enqueue(kind, ticket_ref: context.ref(ticket))
    success(ticket)
  end
end
