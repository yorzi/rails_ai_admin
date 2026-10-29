class CustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :customers
  title :name
  fields do
    id :id
    text :name, required: true, nullable: false, searchable: :prefix, sortable: true
    boolean :active
    integer :points
    datetime :created_at, readonly: true
  end
end
