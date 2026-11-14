# frozen_string_literal: true

# Unregistered resource with explicit index settings, shared by index tests.
class IndexLabelCopy < RailsAiAdmin::Fields::Computation
  version "1"
  def call(values, field:, time_zone:) = values.fetch("name")
end

class IndexedCustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :indexed_customers
  title :name
  fields do
    id :id
    text :name, searchable: :prefix, sortable: true
    text :secret, hidden: true
    integer :points, sortable: true
    boolean :active, index: false
  end
  index do
    columns :points, :name
    default_sort :name, :desc
    page_size 10
    count :exact
  end
end

# Partial-text and empty/not-empty filters on the same customers.
class PartlyFilteredCustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :partly_filtered_customers
  title :name
  fields do
    id :id
    text :name, filterable: %i[contains blank]
    integer :points, filterable: %i[gte blank]
  end
end
