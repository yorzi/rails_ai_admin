class CustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :customers
  title :name
  fields do
    id :id, create: false, tab: "Account", panel: "Context"
    field :name, type: :trimmed_text, required: true, nullable: false, searchable: :prefix, sortable: true, tab: "Identity", panel: "Customer", help_text: "Use the preferred customer name."
    boolean :active, tab: "Account", panel: "Status"
    integer :points, tab: "Account", panel: "Rewards", help_text: "Use whole points."
    readonly :created_at, type: :datetime, create: false, edit: true, tab: "Account", panel: "Context"
    virtual :status_summary, type: :text, depends_on: %i[active points], compute: "CustomerStatusSummary", edit: true, tab: "Account", panel: "Context"
  end
  operation :award_points, handler: "AwardCustomerPoints"
  operation :bulk_award_points, handler: "BulkAwardCustomerPoints", scope: :collection
end
