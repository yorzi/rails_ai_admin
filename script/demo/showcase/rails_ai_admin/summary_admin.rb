class SummaryAdmin < RailsAiAdmin::Resource
  model "Summary"
  key :summaries
  title :text
  navigation group: "Content", order: 2
  fields do
    id :id, create: false
    text :text, required: true, nullable: false, searchable: :contains
    belongs_to :article
  end
end
