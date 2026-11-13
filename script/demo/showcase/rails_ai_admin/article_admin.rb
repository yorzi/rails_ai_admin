# Every everyday field type on a model with timestamps and no lock_version.
class ArticleAdmin < RailsAiAdmin::Resource
  model "Article"
  key :articles
  title :title
  navigation group: "Content", icon: "document", order: 0
  fields do
    id :id, create: false
    text :title, required: true, nullable: false, searchable: :contains, sortable: true
    integer :views, filterable: true, sortable: true
    email :contact, searchable: true
    url :website
    time :opens_at, sortable: true
    file :cover, accept: %w[image/png image/jpeg image/webp image/gif], max_size: 2 * 1024 * 1024
    files :gallery, accept: %w[image/*], max_size: 2 * 1024 * 1024, max_files: 6
    rich_text :body
    json :settings
    references :tags
    password :password, help_text: "An editor password for this article (demo of a write-only field)."
    readonly :created_at, type: :datetime, create: false, sortable: true, filterable: true
    readonly :updated_at, type: :datetime, create: false
  end
  index do
    columns :id, :title, :views, :contact, :opens_at, :cover, :created_at
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
  # With bin/demo --assistant, admin Chat may propose these for review.
  assistant_changes :create, :update, :destroy
end
