# Every everyday field type on a model with timestamps and no lock_version.
class ArticleAdmin < RailsAiAdmin::Resource
  model "Article"
  key :articles
  title :title
  navigation group: "Content", icon: "document", order: 0
  # Deleting keeps the row; admins restore it from Deleted records.
  soft_delete :discarded_at
  fields do
    id :id, create: false, tab: "Details"
    text :title, required: true, nullable: false, searchable: :contains, sortable: true, tab: "Details"
    integer :views, filterable: true, sortable: true, aggregatable: true, tab: "Details"
    email :contact, searchable: true, filterable: %i[contains blank], tab: "Details"
    url :website, filterable: [ :blank ], tab: "Details"
    time :opens_at, sortable: true, tab: "Details"
    readonly :created_at, type: :datetime, create: false, sortable: true, filterable: true, tab: "Details"
    readonly :updated_at, type: :datetime, create: false, tab: "Details"
    rich_text :body, tab: "Content"
    file :cover, accept: %w[image/png image/jpeg image/webp image/gif], max_size: 2 * 1024 * 1024, tab: "Content"
    files :gallery, accept: %w[image/*], max_size: 2 * 1024 * 1024, max_files: 6, tab: "Content"
    json :settings, tab: "Publishing"
    references :tags, tab: "Publishing"
    password :password, tab: "Publishing", help_text: "An editor password for this article (demo of a write-only field)."
  end
  index do
    columns :id, :title, :views, :contact, :created_at
    default_sort :created_at, :desc
    count :exact
  end
  scopes do
    scope :popular, -> { where(views: 50..) }, label: "Popular"
    scope :recent, -> { where(created_at: 7.days.ago..) }, label: "This week"
    scope :all, label: "All articles"
  end
  dashboard do
    metric :all, label: "Articles"
    metric :popular, scope: :popular, label: "Popular articles"
    metric :recent, scope: :recent, label: "Written this week"
    trend :created_at, days: 30, label: "Articles written"
  end
  has_one :summary, resource: :summaries
  # Chat may propose these for review, including one update of many articles.
  assistant_changes :create, :update, :destroy, :bulk_update
end
