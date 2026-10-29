class TicketReceiptWork < RailsAiAdmin::Work
  description "Record a synthetic ticket delivery receipt"
  lease_duration 5
  idempotent true
  input { text :ticket_ref, required: true, nullable: false, max_length: 150 }

  def perform(context, input)
    SyntheticTicketDelivery.call(context, input)
  end
end
