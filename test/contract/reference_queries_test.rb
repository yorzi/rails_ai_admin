# frozen_string_literal: true

require "test_helper"
require "support/database"
require "support/associations"
require "minitest/mock"

# Sorting and searching a list by the title of the record a belongs_to points to.
class ReferenceQueriesTest < Minitest::Test
  include DatabaseHelpers
  include AssociationFixtures

  RESOURCES = %w[AssociationFixtures::CustomerAdmin AssociationFixtures::ReferenceQueryInvoiceAdmin].freeze

  def setup
    reset_database
    AssociationFixtures::Policy.reset!
    AssociationFixtures::Policy.invoice_sort = %i[number customer]
    AssociationFixtures::Policy.invoice_search = %i[number customer]
    @zoe = Customer.create!(account_id: 1, name: "Zoe")
    @ada = Customer.create!(account_id: 1, name: "Ada")
    @mia = Customer.create!(account_id: 1, name: "Mia")
    @foreign = Customer.create!(account_id: 2, name: "Aaron")
    Invoice.create!(account_id: 1, number: "I-1", customer: @zoe)
    Invoice.create!(account_id: 1, number: "I-2", customer: @ada)
    Invoice.create!(account_id: 1, number: "I-3")
    Invoice.create!(account_id: 1, number: "I-4", customer: @mia)
    Invoice.create!(account_id: 1, number: "I-5", customer: @foreign)
    Invoice.create!(account_id: 1, number: "I-6", customer: @ada)
    Invoice.create!(account_id: 2, number: "X-1", customer: @foreign)
  end

  def list(**options)
    with_association_resources(RESOURCES) do |registry|
      RailsAiAdmin::Queries::List.new(context, registry.fetch(:invoices)).call(**options).records.map(&:number)
    end
  end

  def granted(action)
    with_association_resources(RESOURCES) do |registry|
      RailsAiAdmin::Authorization::Access.new(context, registry.fetch(:invoices)).fields(action).map(&:name)
    end
  end

  def test_sorting_by_a_reference_orders_by_the_target_title_with_unavailable_targets_last
    assert_equal %w[I-2 I-6 I-4 I-1 I-3 I-5], list(sort: "customer")
    assert_equal %w[I-1 I-4 I-2 I-6 I-3 I-5], list(sort: "customer", direction: "desc"),
      "a target in another tenant sorts like no target, so its title never orders the list"
    assert_equal 2, with_association_resources(RESOURCES) { |registry|
      RailsAiAdmin::Queries::List.new(context, registry.fetch(:invoices)).count(search: "D").count
    }
  end

  def test_sorting_composes_with_search_filters_and_pages
    assert_equal %w[I-2 I-6], list(sort: "customer", page_size: 2)
    assert_equal %w[I-4 I-1], list(sort: "customer", page_size: 2, page: "2")
    assert_equal %w[I-2 I-6], list(sort: "customer", filters: { "customer" => { "eq" => @ada.id.to_s } })
    assert_equal %w[I-2 I-6 I-4], list(sort: "customer", search: "a"), "Ada twice, then Mia"
  end

  def test_searching_a_reference_matches_the_target_title_inside_the_target_policy
    assert_equal %w[I-2 I-6], list(search: "ad").sort
    assert_equal %w[I-2 I-4 I-6], list(search: "a").sort, "contains, case-insensitive, never the foreign Aaron"
    assert_equal %w[I-3], list(search: "I-3")
    AssociationFixtures::Policy.hidden_customers = [ "Ada" ]
    assert_empty list(search: "ada"), "a target outside the target relation is never matched"
    assert_equal %w[I-4 I-1 I-2 I-3 I-5 I-6], list(sort: "customer")
  end

  def test_the_target_title_grant_decides_whether_a_reference_can_sort_or_search
    assert_equal %i[number customer], granted(:sort)
    assert_equal %i[number customer], granted(:search)
    AssociationFixtures::Policy.customer_sort = []
    AssociationFixtures::Policy.customer_search = []
    assert_equal %i[number], granted(:sort)
    assert_equal %i[number], granted(:search)
    error = assert_raises(RailsAiAdmin::AccessDenied) { list(sort: "customer") }
    assert_equal "INVALID_QUERY", error.code
    AssociationFixtures::Policy.reset!
    AssociationFixtures::Policy.invoice_sort = %i[number customer]
    AssociationFixtures::Policy.deny_customer_index = true
    assert_equal %i[number], granted(:sort), "a target the actor cannot list cannot order another list"
    AssociationFixtures::Policy.reset!
    assert_empty granted(:sort), "the source field still needs its own grant"
  end

  def test_references_and_virtual_fields_still_cannot_sort_or_search
    assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Field.new(:tags, type: :references, sortable: true) }
    assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Field.new(:tags, type: :references, searchable: true) }
    field = RailsAiAdmin::Field.new(:customer, type: :belongs_to, sortable: true, searchable: true)
    assert field.options[:sortable]
  end

  def test_export_and_selection_ids_follow_the_reference_order
    AssociationFixtures::Policy.class_eval { def export_records?(**) = true }
    rows = with_association_resources(RESOURCES) do |registry|
      result = RailsAiAdmin::Presentation::CsvExport.new(context, registry.fetch(:invoices)).call(sort: "customer")
      result.body.lines.drop(1).map { |line| line.split(",")[1].delete("\"") }
    end
    assert_equal %w[I-2 I-6 I-4 I-1 I-3 I-5], rows
    ids = with_association_resources(RESOURCES) do |registry|
      model = Invoice
      RailsAiAdmin::Queries::List.new(context, registry.fetch(:invoices)).relation(sort: "customer").limit(3).pluck(model.arel_table[:id])
    end
    assert_equal Invoice.where(number: %w[I-2 I-6 I-4]).order(:number).pluck(:id).sort, ids.sort
  ensure
    AssociationFixtures::Policy.class_eval { remove_method :export_records? if method_defined?(:export_records?, false) }
  end
end
