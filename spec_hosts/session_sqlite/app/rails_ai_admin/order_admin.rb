class OrderAdmin < RailsAiAdmin::Resource
  model "Order"
  key :orders
  title :number
  navigation group: "Commerce", icon: "shopping-bag", order: 10
  fields do
    id :id, create: false, tab: "Order", panel: "Context"
    text :number, required: true, nullable: false, max_length: 32, searchable: :prefix, sortable: true, tab: "Order", panel: "Commercial details"
    belongs_to :customer, filterable: true, tab: "Order", panel: "Commercial details", help_text: "Choose a customer in this account."
    decimal :total, required: true, nullable: false, filterable: true, tab: "Order", panel: "Commercial details", help_text: "An exact nonnegative amount with at most two fractional digits."
    select :state, choices: [ [ "Draft", "draft" ], [ "Approved", "approved" ], [ "Rejected", "rejected" ] ], filterable: [ :in ], readonly: true, create: false, edit: true, tab: "Order", panel: "Review"
    readonly :review_note, type: :textarea, create: false, edit: true, tab: "Order", panel: "Review"
    readonly :reviewed_at, type: :datetime, create: false, edit: true, tab: "Order", panel: "Review"
    date :delivery_on, filterable: true, sortable: true, tab: "Delivery", panel: "Schedule"
    boolean :expedited, nullable: false, filterable: true, tab: "Delivery", panel: "Schedule"
    text :secret_payment_token, hidden: true
    virtual :review_summary, type: :text, depends_on: %i[number state total], compute: "OrderReviewSummary", edit: true, tab: "Order", panel: "Context"
  end
  index do
    columns :number, :customer, :state, :total, :delivery_on, :expedited, :review_summary
    default_sort :delivery_on, :desc
    page_size 20
    count :exact
  end
  scopes do
    scope :drafts, -> { where(state: "draft") }, label: "Drafts", default: true
    scope :reviewed, -> { where(state: %w[approved rejected]) }, label: "Reviewed"
    scope :expedited, -> { where(expedited: true) }, label: "Expedited"
    scope :all, label: "All orders"
  end
  operation :review_order, handler: "ReviewOrderOperation"
end
