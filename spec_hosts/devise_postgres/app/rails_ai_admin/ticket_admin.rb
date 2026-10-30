class TicketAdmin < RailsAiAdmin::Resource
  model "SupportTicket"
  key :tickets
  policy "TicketPolicy"
  title :subject
  fields do
    id :id
    field :subject, type: :trimmed_text, required: true, nullable: false, searchable: :prefix, sortable: true
    select :state, choices: [ [ "Open", "open" ], [ "Triaged", "triaged" ], [ "Closed", "closed" ] ], nullable: false
    integer :priority, sortable: true
    textarea :internal_note
    virtual :review_summary, type: :text, max_length: 2500, depends_on: %i[state priority internal_note], compute: "TicketReviewSummary"
  end
  operation :triage, handler: "TriageTicketOperation"
  operation :bulk_triage, handler: "BulkTriageTicketsOperation", scope: :collection
end
