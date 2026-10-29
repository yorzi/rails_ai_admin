class ClosedTicketAdmin < RailsAiAdmin::Resource
  model "SupportTicket"
  key :closed_tickets
  policy "ClosedTicketPolicy"
  title :subject
  readonly
  fields do
    id :id
    text :subject, searchable: :prefix
    enum :state, values: %w[open triaged closed]
  end
end
