class CustomerDirectoryAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :directory
  label "Customer directory"
  title :name
  readonly
  fields do
    id :id
    text :name, searchable: :prefix, sortable: true
  end
end
