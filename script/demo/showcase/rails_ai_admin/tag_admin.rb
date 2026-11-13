class TagAdmin < RailsAiAdmin::Resource
  model "Tag"
  key :tags
  title :name
  navigation group: "Content", order: 1
  fields do
    id :id, create: false
    text :name, required: true, nullable: false, searchable: :contains, sortable: true
  end
end
