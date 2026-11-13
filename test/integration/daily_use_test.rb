# frozen_string_literal: true

require "test_helper"
require "support/application"
require "minitest/mock"

# Phase 4 regressions from the 2026-11-10 audit: the gap between correct and
# pleasant in everyday pages.
class DailyUseTest < ActionDispatch::IntegrationTest
  include DatabaseHelpers

  class ValidatedCustomer < ActiveRecord::Base
    self.table_name = "customers"
    validates :points, numericality: { less_than: 100 }
    validate { errors.add(:base, "Accounts named nobody cannot be saved") if name == "nobody" }
  end

  class EmailType < RailsAiAdmin::Fields::Type
    scalar :text
    version "1"
    def valid?(value, **) = value.include?("@") || "must contain an @ sign"
  end

  class CustomerAdmin < RailsAiAdmin::Resource
    model "DailyUseTest::ValidatedCustomer"
    key :daily_customers
    label "Daily customers"
    title :name
    fields do
      id :id
      text :name, required: true, nullable: false, searchable: :contains, sortable: true
      text :secret, sortable: true
      textarea :notes_view, readonly: true, edit: true, create: false, index: false, show: true
      integer :points, filterable: true
      boolean :active, readonly: true, create: false, edit: true
    end
  end

  class Policy < TestPolicy
    def fields(context:, resource:, action:, record: nil)
      return super unless resource.key == :daily_customers
      { read: %i[id name secret points active], write: %i[name points], search: %i[name], sort: %i[name secret], filter: %i[points] }.fetch(action, [])
    end
  end

  class SelectionPolicy < TestPolicy
    def select_records?(**) = true
  end

  def setup
    reset_database
    post "/test/sign_in/1"
  end

  def with_daily(**settings)
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = "DailyUseTest::Policy"
    settings.each { |name, value| config.public_send("#{name}=", value) }
    registry = RailsAiAdmin::Registry.new([ "DailyUseTest::CustomerAdmin" ])
    operations = RailsAiAdmin::Operations::Registry.new(registry.resources)
    RailsAiAdmin.stub(:configuration, config) do
      RailsAiAdmin.stub(:registry, registry) do
        RailsAiAdmin.stub(:operation_registry, operations) { yield }
      end
    end
  end

  def intent = css_select("input[name=intent_ref]").first["value"]
  def edit_and_patch(record)
    get "/backoffice/daily_customers/#{@customer.id}/edit"
    patch "/backoffice/daily_customers/#{@customer.id}", params: { intent_ref: intent, record: record }
  end

  def test_raa_011_model_messages_reach_the_person_unless_generic_is_configured
    with_daily do
      edit_and_patch(points: "150", name: "nobody")
      assert_response :unprocessable_content
      assert_select ".raa-errors a", text: "Points must be less than 100"
      assert_select ".raa-errors li", text: "Accounts named nobody cannot be saved"
      assert_select ".raa-field-error", text: "must be less than 100"
    end
    with_daily(validation_messages: :generic) do
      edit_and_patch(points: "150", name: "Alice")
      assert_select ".raa-field-error", text: "is invalid"
      refute_includes response.body, "less than 100"
    end
    assert_equal "Alice", @customer.reload.name
  end

  def test_raa_011_a_field_type_can_explain_a_rejection
    field = RailsAiAdmin::Fields::Registry.new(contact_email: "DailyUseTest::EmailType").build(:email, type: :contact_email)
    error = assert_raises(ArgumentError) { field.coerce("not-an-address") }
    assert_equal "must contain an @ sign", error.message
    assert_equal "a@b", field.coerce("a@b")
  end

  def test_raa_023_required_fields_are_marked_and_readonly_values_are_not_live_regions
    with_daily do
      get "/backoffice/daily_customers/#{@customer.id}/edit"
      assert_select "input[name='record[name]'][required][aria-required=true]"
      assert_select "label .raa-required", text: "*", count: 1
      assert_select "input[name='record[points]'][required]", count: 0
      assert_select "p.raa-field-help", text: /Fields marked\s+\*\s*with an asterisk\s+are required/
      assert_select "output", count: 0
      assert_select ".raa-readonly[role=group][aria-labelledby]", text: "Yes"
    end
  end

  def test_raa_024_titles_headings_cancel_and_header
    with_daily do
      get "/backoffice/daily_customers"
      assert_select "title", text: "Daily customers · Administration"
      assert_select ".raa-header", text: /Development preview/, count: 0
      get "/backoffice/daily_customers/#{@customer.id}/edit"
      assert_select "title", text: "Edit Alice · Daily customers · Administration"
      assert_select "h1", text: "Edit Alice"
      assert_select "a[href='/backoffice/daily_customers/#{@customer.id}']", text: "Cancel"
      get "/backoffice/daily_customers/new"
      assert_select "h1", text: "New daily customer"
    end
    with_daily(environment_label: "Staging") do
      get "/backoffice/daily_customers"
      assert_select ".raa-header .raa-environment", text: "Staging"
    end
  end

  def test_raa_024_a_signed_out_page_visit_goes_to_sign_in_and_form_posts_keep_the_401
    guest = open_session
    with_daily(authentication_path: "/session/new") do
      guest.get "/backoffice/daily_customers/#{@customer.id}", params: { q: "private search" }
      assert_equal 303, guest.response.status
      assert_equal "/session/new?return_to=%2Fbackoffice%2Fdaily_customers%2F#{@customer.id}", URI(guest.response.location).request_uri
      guest.patch "/backoffice/daily_customers/#{@customer.id}", params: { intent_ref: "x", record: { name: "x" } }
      assert_equal 401, guest.response.status
      guest.get "/backoffice/daily_customers", headers: { "Turbo-Frame" => "list" }
      assert_equal 401, guest.response.status
    end
    guest.get "/backoffice/daily_customers"
    assert_equal 401, guest.response.status, "without authentication_path the status page stays"
  end

  def test_raa_025_list_puts_records_first
    Customer.create!(account_id: 1, name: "Bob", points: 5)
    with_daily do
      get "/backoffice/daily_customers"
      assert_select ".raa-list-toolbar form.raa-search[role=search] input[name=q][placeholder='Contains…']" do |inputs|
        assert_equal "24", inputs.first["size"]
        assert_equal "200", inputs.first["maxlength"]
      end
      assert_select ".raa-table-scroll[tabindex='0'] > table"
      assert_select "details.raa-filter-panel:not([open]) form.raa-filters"
      assert_select "a", text: "Edit"
      get "/backoffice/daily_customers", params: { filter: { points: { gte: "1" } } }
      assert_select "details.raa-filter-panel[open] summary", text: "Filters (1 active)"
    end
  end

  def test_raa_025_selection_bar_has_a_select_all_for_the_page
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = "DailyUseTest::SelectionPolicy"
    RailsAiAdmin.stub(:configuration, config) do
      get "/backoffice/customers"
      assert_select "form#raa-selection.raa-selection-bar"
      assert_select "th input[type=checkbox][data-raa-select-all][hidden]:not([name])"
    end
  end

  def test_raa_021_search_trims_input
    with_daily do
      get "/backoffice/daily_customers", params: { q: "  lic " }
      assert_response :success
      assert_select "tbody tr", count: 1
      assert_select "input[name=q][value=lic]"
    end
  end

  def test_raa_022_only_canonical_ids_address_a_record
    with_daily do
      [ "#{@customer.id}abc", "0#{@customer.id}", " #{@customer.id}" ].each do |id|
        get "/backoffice/daily_customers/#{ERB::Util.url_encode(id)}"
        assert_response :not_found, id
      end
      # A format suffix no longer selects record 1 in format "5": no route (404).
      assert_raises(ActionController::RoutingError) { get "/backoffice/daily_customers/#{@customer.id}.5" }
      get "/backoffice/daily_customers/#{@customer.id}"
      assert_response :success
    end
  end

  def test_raa_028_empty_values_sort_last_in_both_directions
    Customer.create!(account_id: 1, name: "Bob", secret: "b")
    Customer.create!(account_id: 1, name: "Carol", secret: "a")
    Customer.create!(account_id: 1, name: "Dave", secret: nil)
    with_daily do
      %w[asc desc].each do |direction|
        records = RailsAiAdmin::Queries::List.new(context, CustomerAdmin).call(sort: "secret", direction: direction).records
        assert_nil records.last.secret, direction
      end
    end
  end

  def test_raa_030_jobs_page_follows_its_menu_link
    get "/backoffice/jobs"
    assert_response :not_found
  end
end
