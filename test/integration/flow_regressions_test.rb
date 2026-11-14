# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/associations"
require "minitest/mock"
require "rails_ai_admin/test_kit"

# Phase 2 regressions from the 2026-11-10 audit: pages that 404, dead-end or
# write on GET during ordinary use.
class FlowRegressionsTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include AssociationFixtures

  class RowPolicy < TestPolicy
    class_attribute :hidden_id
    def allowed?(context:, action:, resource:, record: nil)
      return false if action == :show && record && record.id == hidden_id
      super
    end
    def select_records?(**) = true
  end

  # Customers that also restrict deletion while invoices exist.
  class RestrictedCustomer < ActiveRecord::Base
    self.table_name = "customers"
    has_many :invoices, foreign_key: :customer_id, dependent: :restrict_with_error
  end

  class RestrictedCustomerAdmin < RailsAiAdmin::Resource
    model "FlowRegressionsTest::RestrictedCustomer"
    key :restricted_customers
    title :name
    fields do
      id :id
      text :name
    end
  end

  class ScopedInvoiceAdmin < RailsAiAdmin::Resource
    model "Invoice"
    key :invoices
    title :number
    fields do
      id :id
      text :number, required: true, nullable: false
      belongs_to :customer, filterable: true
    end
    scopes do
      scope :drafts, -> { where("number LIKE ?", "D-%") }, label: "Drafts", default: true
      scope :all, label: "All invoices"
    end
  end

  class ScopedPolicy < AssociationFixtures::Policy
    def named_scopes(**) = %i[drafts all]
  end

  def setup
    reset_database
    AssociationFixtures::Policy.reset!
    RowPolicy.hidden_id = nil
    post "/test/sign_in/1"
  end

  def with_adapter(name, resources: nil)
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = name
    registry = resources ? RailsAiAdmin::Registry.new(resources) : RailsAiAdmin.registry
    operations = RailsAiAdmin::Operations::Registry.new(registry.resources)
    RailsAiAdmin.stub(:configuration, config) do
      RailsAiAdmin.stub(:registry, registry) do
        RailsAiAdmin.stub(:operation_registry, operations) { yield }
      end
    end
  end

  def intent = css_select("input[name=intent_ref]").first["value"]

  def test_raa_001_a_row_that_denies_show_is_omitted_instead_of_failing_the_list
    bob = Customer.create!(account_id: 1, name: "Bob")
    RowPolicy.hidden_id = bob.id
    with_adapter("FlowRegressionsTest::RowPolicy") do
      get "/backoffice/customers"
      assert_response :success
      assert_includes response.body, "Alice"
      refute_includes response.body, "Bob"
      assert_select "p.raa-notice", text: "Some records on this page are not available to you."
      assert_select "p", text: "No records match this query.", count: 0

      error = assert_raises(RailsAiAdmin::TestKit::AssertionError) do
        RailsAiAdmin::TestKit.assert_scope_matches_show(context: context, resource: TestResource)
      end
      assert_includes error.message, "1 of 2 sampled customers records"
      refute_includes error.message, "Bob"
      RowPolicy.hidden_id = nil
      assert RailsAiAdmin::TestKit.assert_scope_matches_show(context: context, resource: TestResource)
      get "/backoffice/customers"
      assert_select "p.raa-notice", count: 0
    end
  end

  def test_raa_006_view_all_shows_every_child_like_the_panel_does
    Invoice.create!(account_id: 1, number: "INV-1", customer: @customer)
    Invoice.create!(account_id: 1, number: "D-2", customer: @customer)
    resources = %w[AssociationFixtures::CustomerAdmin FlowRegressionsTest::ScopedInvoiceAdmin]
    with_adapter("FlowRegressionsTest::ScopedPolicy", resources: resources) do
      get "/backoffice/customers/#{@customer.id}"
      assert_response :success
      assert_equal %w[INV-1 D-2], css_select("section.raa-association li > :first-child").map(&:text)
      link = css_select("section.raa-association a").find { |node| node.text == "View all in Invoices" }
      query = Rack::Utils.parse_nested_query(URI(link["href"]).query)
      assert_equal({ "filter" => { "customer" => { "eq" => @customer.id.to_s } }, "scope" => "_none" }, query)
      get link["href"]
      assert_response :success
      assert_equal %w[D-2 INV-1], css_select("tbody tr").map { |row| row.text[/(?:INV|D)-\d/] }.sort
      assert_select "p.raa-notice", text: "Showing every record you can access, without a list tab."
      assert_select ".raa-scopes a[aria-current]", count: 0
      # The default tab still applies when no state is given.
      get "/backoffice/invoices", params: { filter: { customer: { eq: @customer.id.to_s } } }
      assert_equal %w[D-2], css_select("tbody tr").map { |row| row.text[/(?:INV|D)-\d/] }
      # Reserved-looking names other than _none are still invalid.
      get "/backoffice/invoices", params: { scope: "_all" }
      assert_response :unprocessable_content
    end
  end

  def test_raa_006_no_list_tab_is_dropped_where_no_default_tab_applies
    with_association_resources do
      get "/backoffice/invoices", params: { scope: "_none" }
      assert_response :success
      assert_select "p.raa-notice", text: /without a list tab/, count: 0
    end
  end

  def test_raa_013_an_empty_selection_returns_to_the_list_and_duplicates_collapse
    with_adapter("FlowRegressionsTest::RowPolicy") do
      get "/backoffice/customers"
      assert_select "form#raa-selection[data-controller='raa-selection'] button[type=submit][data-raa-selection-target='submit']", text: "Review selection"
      post "/backoffice/customers/selections", params: { return_to: { q: "Al" } }
      assert_response :see_other
      assert_equal "/backoffice/customers?q=Al", URI(response.location).request_uri
      follow_redirect!
      assert_select "p.raa-notice", text: "Select at least one record."
      post "/backoffice/customers/selections", params: { target_ids: [ @customer.id, @customer.id.to_s ] }
      assert_response :see_other
      assert_match %r{/backoffice/selections/}, response.location
      assert_equal 1, RailsAiAdmin::SelectionItem.count
    end
    # Without the selection grant the shortcut does not reveal the list.
    post "/backoffice/customers/selections"
    assert_response :not_found
  end

  def test_raa_012_a_delete_blocked_by_references_says_so_and_can_be_retried
    invoice = Invoice.create!(account_id: 1, number: "INV-9", customer: @customer)
    with_association_resources do
      get "/backoffice/customers/#{@customer.id}/confirm_destroy"
      reference = intent
      delete "/backoffice/customers/#{@customer.id}", params: { intent_ref: reference }
      assert_response :unprocessable_content
      assert_includes response.body, "This record is still referenced by other records and cannot be deleted."
      refute_includes response.body, "Open a fresh form"
      assert_select "input[type=submit][value='Confirm deletion']:not([disabled])"
      assert_equal "RESTRICTED", RailsAiAdmin::AuditEvent.where(status: "rejected").last.code
      invoice.destroy!
      delete "/backoffice/customers/#{@customer.id}", params: { intent_ref: reference }
      assert_response :see_other
      refute Customer.exists?(@customer.id)
    end
  end

  def test_raa_012_restrict_with_error_messages_reach_the_user
    Invoice.create!(account_id: 1, number: "INV-8", customer: @customer)
    with_adapter("TestPolicy", resources: [ "FlowRegressionsTest::RestrictedCustomerAdmin" ]) do
      get "/backoffice/restricted_customers/#{@customer.id}/confirm_destroy"
      delete "/backoffice/restricted_customers/#{@customer.id}", params: { intent_ref: intent }
      assert_response :unprocessable_content
      assert_includes response.body, "Cannot delete record because dependent invoices exist"
      assert Customer.exists?(@customer.id)
    end
  end

  def test_raa_005_form_pages_write_nothing_until_the_form_is_submitted
    get "/backoffice/customers/new"
    get "/backoffice/customers/#{@customer.id}/edit"
    get "/backoffice/customers/#{@customer.id}/confirm_destroy"
    assert_response :success
    assert_equal 0, RailsAiAdmin::OperationRun.count
    get "/backoffice/customers/#{@customer.id}/edit"
    reference = intent
    refute RailsAiAdmin::Operations::FormIntent.uuid?(reference)

    # Another actor, a tampered reference or another record cannot use it.
    post "/test/sign_in/2"
    patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: reference, record: { name: "Attack" } }
    assert_response :not_found
    post "/test/sign_in/1"
    patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: reference.sub(/.\z/) { |char| char == "a" ? "b" : "a" }, record: { name: "Tampered" } }
    assert_response :not_found
    second = Customer.create!(account_id: 1, name: "Second")
    patch "/backoffice/customers/#{second.id}", params: { intent_ref: reference, record: { name: "Moved" } }
    assert_response :not_found
    assert_equal [ "Alice", "Second" ], [ @customer.reload.name, second.reload.name ]

    patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: reference, record: { name: "Edited" } }
    assert_response :see_other
    assert_equal 1, RailsAiAdmin::OperationRun.where(status: "succeeded").count
    # Submitting the same form again replays the first receipt.
    patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: reference, record: { name: "Edited" } }
    assert_response :see_other
    assert_equal 1, @customer.reload.lock_version
    assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
  end

  def test_raa_005_an_expired_form_reference_is_rejected_as_expired
    get "/backoffice/customers/#{@customer.id}/edit"
    reference = intent
    travel 16.minutes do
      patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: reference, record: { name: "Late" } }
    end
    assert_response :conflict
    assert_includes response.body, RailsAiAdmin::Presentation::Outcomes.sentence("APPROVAL_EXPIRED")
    assert_equal "Alice", @customer.reload.name
  end
end
