class ClosedTicketReceiptWork < RailsAiAdmin::Work
  description "Record a synthetic non-idempotent close receipt"
  lease_duration 5
  input { text :ticket_ref, required: true, nullable: false, max_length: 150 }

  def perform(context, input)
    SyntheticTicketDelivery.call(context, input)
  end
end
