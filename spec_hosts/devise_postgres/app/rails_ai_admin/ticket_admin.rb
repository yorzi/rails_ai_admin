class TicketAdmin < RailsAiAdmin::Resource
  model "SupportTicket"
  key :tickets
  policy "TicketPolicy"
  title :subject
  fields do
    id :id
    text :subject, required: true, nullable: false, searchable: :prefix, sortable: true
    enum :state, values: %w[open triaged closed], nullable: false
    integer :priority, sortable: true
    textarea :internal_note
  end
  operation :triage, handler: "TriageTicketOperation"
  operation :bulk_triage, handler: "BulkTriageTicketsOperation", scope: :collection
end
