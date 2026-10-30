class CustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :customers
  title :name
  fields do
    id :id
    field :name, type: :trimmed_text, required: true, nullable: false, searchable: :prefix, sortable: true
    boolean :active
    integer :points
    readonly :created_at, type: :datetime
  end
  operation :award_points, handler: "AwardCustomerPoints"
  operation :bulk_award_points, handler: "BulkAwardCustomerPoints", scope: :collection
end
