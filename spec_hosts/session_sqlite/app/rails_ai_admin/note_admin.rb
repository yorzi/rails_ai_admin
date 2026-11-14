class NoteAdmin < RailsAiAdmin::Resource
  model "Note"
  key :notes
  title :body
  navigation group: "People", icon: "document", order: 20
  # Deleting keeps the row; admins restore it from Deleted records.
  soft_delete :discarded_at
  fields do
    id :id, create: false
    text :body, required: true, nullable: false, max_length: 500, searchable: :contains, sortable: true
    readonly :created_at, type: :datetime, create: false, sortable: true
  end
  index do
    default_sort :created_at, :desc
  end
end
