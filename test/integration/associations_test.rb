# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/associations"

class AssociationsIntegrationTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include AssociationFixtures

  def setup
    reset_database
    AssociationFixtures::Policy.reset!
    post "/test/sign_in/1"
    @bob = Customer.create!(account_id: 1, name: "Bob <b>bold</b>")
  end

  def intent = css_select("input[name=intent_ref]").first["value"]

  def test_index_labels_references_through_target_grants_without_per_row_queries
    Invoice.create!(account_id: 1, number: "INV-1", customer: @customer)
    Invoice.create!(account_id: 1, number: "INV-2", customer: @bob)
    Invoice.create!(account_id: 1, number: "INV-3")
    # A corrupt cross-tenant reference must render as an unlinked placeholder.
    Invoice.create!(account_id: 1, number: "INV-4", customer: @other)
    # The filter picker would cache every visible target; measure the table alone.
    AssociationFixtures::Policy.invoice_filters = []
    with_association_resources do
      few = count_queries { get "/backoffice/invoices" }
      assert_response :success
      assert_select "td a[href='/backoffice/customers/#{@customer.id}']", text: "Alice"
      assert_select "td a[href='/backoffice/customers/#{@bob.id}']", text: "Bob <b>bold</b>"
      refute_includes response.body, "<b>bold</b>"
      assert_select "td", text: "Customer ##{@other.id}"
      assert_select "td a[href='/backoffice/customers/#{@other.id}']", count: 0
      refute_includes response.body, "Other tenant"
      8.times { |index| Invoice.create!(account_id: 1, number: "INV-#{index + 10}", customer: Customer.create!(account_id: 1, name: "C#{index}")) }
      many = count_queries { get "/backoffice/invoices" }
      assert_response :success
      assert_equal few, many, "reference labels must not add a query per row"
    end
  end

  def test_show_links_the_reference_and_lists_bounded_children_with_a_filtered_view_all
    invoices = Array.new(3) { |index| Invoice.create!(account_id: 1, number: "INV-#{index}", customer: @customer) }
    Invoice.create!(account_id: 1, number: "INV-BOB", customer: @bob)
    with_association_resources do
      get "/backoffice/invoices/#{invoices.first.id}"
      assert_response :success
      assert_select "dd a[href='/backoffice/customers/#{@customer.id}']", text: "Alice"

      get "/backoffice/customers/#{@customer.id}"
      assert_response :success
      assert_select "section.raa-association h2#raa-association-invoices", text: "Invoices"
      assert_equal %w[INV-0 INV-1], css_select("section.raa-association li a").map(&:text)
      refute_includes response.body, "INV-BOB"
      view_all = css_select("section.raa-association a").find { |node| node.text == "View all in Invoices" }
      assert view_all
      query = Rack::Utils.parse_nested_query(URI(view_all["href"]).query)
      assert_equal({ "filter" => { "customer" => { "eq" => @customer.id.to_s } } }, query)
      get view_all["href"]
      assert_response :success
      assert_equal %w[INV-0 INV-1 INV-2], css_select("tbody tr").map { |row| row.text[/INV-\w+/] }

      AssociationFixtures::Policy.invoice_filters = []
      get "/backoffice/customers/#{@customer.id}"
      assert_select "section.raa-association a", text: /View all/, count: 0
      assert_select "section.raa-association p", text: "Showing the first 2."

      # Without a read grant on the back-reference, the panel would reveal it.
      AssociationFixtures::Policy.invoice_read = %i[id number]
      get "/backoffice/customers/#{@customer.id}"
      assert_response :success
      assert_select "section.raa-association", count: 0
    end
  end

  def test_forms_offer_only_visible_targets_and_create_through_the_runner
    with_association_resources do
      get "/backoffice/invoices/new"
      assert_response :success
      options = css_select("select[name='record[customer]'] option").map { |node| [ node.text, node["value"] ] }
      assert_equal [ [ "None", "" ], [ "Alice", @customer.id.to_s ], [ "Bob <b>bold</b>", @bob.id.to_s ] ], options
      refute_includes response.body, "Other tenant"

      post "/backoffice/invoices", params: { intent_ref: intent, record: { number: "INV-NEW", customer: @bob.id.to_s } }
      assert_response :see_other
      assert_equal @bob.id, Invoice.find_by!(number: "INV-NEW").customer_id

      get "/backoffice/invoices/new"
      post "/backoffice/invoices", params: { intent_ref: intent, record: { number: "INV-BAD", customer: @other.id.to_s } }
      assert_response :unprocessable_content
      assert_select ".raa-field-error", text: "is not an available choice"
      assert_select "select[name='record[customer]'] option[selected]", text: "Customer ##{@other.id} (not available)"
      refute Invoice.exists?(number: "INV-BAD")
    end
  end

  def test_editing_keeps_an_unavailable_stored_reference_selected
    invoice = Invoice.create!(account_id: 1, number: "INV-1", customer: @customer)
    AssociationFixtures::Policy.hidden_customers = [ "Alice" ]
    with_association_resources do
      get "/backoffice/invoices/#{invoice.id}/edit"
      assert_response :success
      selected = css_select("select[name='record[customer]'] option[selected]").first
      assert_equal [ "Customer ##{@customer.id} (not available)", @customer.id.to_s ], [ selected.text, selected["value"] ]
      refute_includes response.body, "Alice"
      patch "/backoffice/invoices/#{invoice.id}", params: { intent_ref: intent, record: { number: "INV-1b", customer: @customer.id.to_s } }
      assert_response :see_other
      assert_equal [ "INV-1b", @customer.id ], invoice.reload.then { |record| [ record.number, record.customer_id ] }
    end
  end

  def test_large_or_unlistable_targets_fall_back_to_a_typed_key
    AssociationFixtures::Policy.deny_customer_index = true
    with_association_resources do
      get "/backoffice/invoices/new"
      assert_response :success
      assert_select "select[name='record[customer]']", count: 0
      assert_select "input[type=text][name='record[customer]'][placeholder='Customer ID'][maxlength='100']"
      post "/backoffice/invoices", params: { intent_ref: intent, record: { number: "INV-T", customer: @customer.id.to_s } }
      assert_response :see_other
      assert_equal @customer.id, Invoice.find_by!(number: "INV-T").customer_id
    end
  end

  def test_reference_filters_render_current_choices
    Invoice.create!(account_id: 1, number: "INV-A", customer: @customer)
    Invoice.create!(account_id: 1, number: "INV-B", customer: @bob)
    with_association_resources do
      get "/backoffice/invoices", params: { filter: { customer: { eq: @bob.id.to_s } } }
      assert_response :success
      assert_select "select#raa-filter-customer-eq[name='filter[customer][eq]'] option[selected][value='#{@bob.id}']", text: "Bob <b>bold</b>"
      assert_select "select#raa-filter-customer-eq option", text: "Other tenant", count: 0
      assert_equal [ "INV-B" ], css_select("tbody tr").map { |row| row.text[/INV-\w+/] }
    end
  end
end
