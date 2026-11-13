# Every everyday field type on a model with timestamps and no lock_version.
class ArticleAdmin < RailsAiAdmin::Resource
  model "Article"
  key :articles
  title :title
  navigation group: "Content", icon: "document", order: 0
  index { count :exact }
  fields do
    id :id, create: false
    text :title, required: true, nullable: false, searchable: :contains, sortable: true
    integer :views, filterable: true, sortable: true
    email :contact, searchable: true
    url :website
    time :opens_at, sortable: true
    file :cover, accept: %w[image/png image/jpeg image/webp image/gif], max_size: 2 * 1024 * 1024
    rich_text :body
    json :settings
    references :tags
    password :password, help_text: "An editor password for this article (demo of a write-only field)."
    readonly :updated_at, type: :datetime, create: false
  end
  has_one :summary, resource: :summaries
end
