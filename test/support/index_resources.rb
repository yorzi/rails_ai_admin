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
