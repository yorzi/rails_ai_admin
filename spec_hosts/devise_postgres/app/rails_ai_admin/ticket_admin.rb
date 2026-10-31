class TicketAdmin < RailsAiAdmin::Resource
  model "SupportTicket"
  key :tickets
  policy "TicketPolicy"
  title :subject
  navigation group: "Support", label: "Support queue", icon: "life-buoy"
  fields do
    id :id, create: false, tab: "Review", panel: "Context"
    field :subject, type: :trimmed_text, required: true, nullable: false, searchable: :prefix, sortable: true, tab: "Ticket", panel: "Details"
    select :state, choices: [ [ "Open", "open" ], [ "Triaged", "triaged" ], [ "Closed", "closed" ] ], nullable: false, tab: "Review", panel: "Classification"
    integer :priority, sortable: true, tab: "Review", panel: "Classification", help_text: "Use an integer priority."
    textarea :internal_note, tab: "Review", panel: "Notes", help_text: "Only current operators and administrators can read this note."
    virtual :review_summary, type: :text, max_length: 2500, depends_on: %i[state priority internal_note], compute: "TicketReviewSummary", edit: true, tab: "Review", panel: "Context"
  end
  # No default: the unscoped queue remains the authorized policy relation.
  scopes do
    scope :open, -> { where(state: "open") }
    scope :triaged, -> { where(state: "triaged") }
    scope :missing_note, -> { where(internal_note: [ nil, "" ]) }, label: "Missing internal note"
  end
  operation :triage, handler: "TriageTicketOperation"
  operation :bulk_triage, handler: "BulkTriageTicketsOperation", scope: :collection
end
