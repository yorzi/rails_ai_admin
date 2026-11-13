# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/collections"

class ListNavigationTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include OperationContractHelpers
  include CollectionContractHelpers

  class NoIndexPolicy < TestPolicy
    def allowed?(action:, **) = action != :index && super
  end

  def setup
    reset_database
    post "/test/sign_in/1"
    @state = { "q" => "Alice", "sort" => "name", "direction" => "desc", "page" => "2" }
  end

  def intent = css_select("input[name=intent_ref]").first["value"]
  def query(url) = Rack::Utils.parse_nested_query(URI(url).query)
  def main_link(text) = css_select("main a").find { |node| node.text == text }["href"]
  def assert_hidden_state(state = @state)
    state.each { |key, value| assert_select "input[name='return_to[#{key}]'][value='#{value}']" }
  end

  def test_index_carries_page_sort_search_to_members_and_new_and_resets_page_on_query_change
    26.times { Customer.create!(account_id: 1, name: "Alice") }
    get "/backoffice/customers", params: @state
    assert_response :success
    view = css_select("main a.raa-row-title").first
    assert_equal @state, query(view["href"])["return_to"]
    assert_equal @state, query(main_link("New customer"))["return_to"]
    assert_select "th[aria-sort=descending] a", text: "Name"
    assert_equal "asc", query(main_link("Name"))["direction"]
    refute query(main_link("Name")).key?("page")
    assert_select "form.raa-search input[name=sort][value=name]"
    assert_select "form.raa-search input[name=direction][value=desc]"
    assert_select "form.raa-search input[name=page]", count: 0
    assert_equal @state.except("page"), query(main_link("Previous"))
  end

  def test_generic_show_edit_validation_success_and_cancel_preserve_only_list_hints
    get "/backoffice/customers/#{@customer.id}", params: { return_to: @state }
    assert_equal @state, query(main_link("Customers"))
    get main_link("Edit")
    assert_response :success
    assert_hidden_state
    form = css_select("form[data-controller~='raa-form-recovery']").first
    assert_nil URI(form["action"]).query
    # Cancel on an edit form returns to the record, keeping the list hints (RAA-024).
    assert_equal "/backoffice/customers/#{@customer.id}", URI(main_link("Cancel")).path
    assert_equal({ "return_to" => @state }, query(main_link("Cancel")))
    ref = intent
    patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: ref, return_to: @state, record: { name: "" } }
    assert_response :unprocessable_content
    assert_hidden_state
    patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: ref, return_to: @state, record: { name: "Edited outside original search" } }
    assert_response :see_other
    assert_equal @state, query(response.location)["return_to"]
    follow_redirect!
    assert_equal @state, query(main_link("Customers"))
    assert_equal "Edited outside original search", @customer.reload.name
  end

  def test_url_injection_never_controls_a_redirect_and_navigation_does_not_change_replay_identity
    [ "//evil.test/path", "https://evil.test", { host: "evil.test" }, { controller: "sessions", action: "destroy" }, { resource: "uuid_customers" } ].each do |raw|
      get "/backoffice/customers/#{@customer.id}", params: { return_to: raw }
      assert_response :success
      assert_equal "/backoffice/customers", main_link("Customers")
      assert_select ".raa-notice", text: /Some list settings/
      refute_includes response.body, "evil.test"
    end
    get "/backoffice/customers/new", params: { return_to: @state }
    ref = intent
    count = Customer.count
    2.times do |index|
      post "/backoffice/customers", params: { intent_ref: ref, return_to: index.zero? ? @state : "//evil.test", record: { name: "Created once" } }
      assert_response :see_other
      assert_equal "www.example.com", URI(response.location).host
    end
    follow_redirect!
    assert_select ".raa-notice", text: /Some list settings/
    assert_equal count + 1, Customer.count
    assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
  end

  def test_revoked_query_grants_fall_back_once_and_invalid_sql_shape_still_fails
    TestPolicy.hide_name = true
    get "/backoffice/customers", params: @state
    assert_response :see_other
    assert_equal "/backoffice/customers", URI(response.location).path
    assert_empty query(response.location)
    follow_redirect!
    assert_response :success
    assert_select ".raa-notice", text: /Some list settings/
    get "/backoffice/customers", params: { sort: "name DESC; DROP TABLE customers" }
    assert_response :unprocessable_content
    assert Customer.exists?(@customer.id)
  end

  def test_deleting_the_last_filtered_page_clamps_within_the_current_tenant_and_filter
    26.times { |index| Customer.create!(account_id: 1, name: "Visit #{index.to_s.rjust(2, '0')}") }
    30.times { Customer.create!(account_id: 2, name: "Visit foreign") }
    state = { "q" => "Visit", "sort" => "name", "page" => "2" }
    target = RailsAiAdmin::Queries::List.new(context, TestResource).call(search: "Visit", sort: "name", page: "2").records.first
    get "/backoffice/customers/#{target.id}/confirm_destroy", params: { return_to: state }
    assert_response :success
    ref = intent
    delete "/backoffice/customers/#{target.id}", params: { intent_ref: ref, return_to: state }
    assert_response :see_other
    assert_equal state, query(response.location)
    follow_redirect!
    assert_response :see_other
    assert_equal state.except("page"), query(response.location)
    follow_redirect!
    assert_response :success
    assert_select "tbody tr", count: 25
    refute_includes response.body, "Visit foreign"
    refute_includes response.body, "Alice"
    assert_select ".raa-notice", text: /page is now empty/
  end

  def test_recovery_preserves_unicode_list_state_through_a_bounded_ascii_header
    state = @state.merge("q" => "客户 🚀")
    get "/backoffice/customers/#{@customer.id}/edit", params: { return_to: state }
    ref = intent
    form = css_select("form[data-raa-form-recovery-return-state-value]").first
    encoded = form["data-raa-form-recovery-return-state-value"]
    assert encoded.ascii_only?
    get "/backoffice/customers/forms/recover", headers: { "X-RailsAiAdmin-Recovery-Intent" => ref, "X-RailsAiAdmin-Return-State" => encoded }
    assert_response :success
    assert_hidden_state(state)
    assert_includes response.headers["Vary"], "X-RailsAiAdmin-Return-State"
    assert_equal({ "return_to" => state }, query(main_link("Cancel")))
    get "/backoffice/customers/forms/recover", headers: { "X-RailsAiAdmin-Recovery-Intent" => ref, "X-RailsAiAdmin-Return-State" => "!bad!" }
    assert_response :success
    assert_equal "/backoffice/customers/#{@customer.id}", main_link("Cancel")
    assert_select "input[name^='return_to']", count: 0
    assert_select ".raa-notice", text: /Some list settings/
  end

  def test_a_member_only_user_returns_to_the_dashboard_without_list_state
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = "ListNavigationTest::NoIndexPolicy"
    RailsAiAdmin.stub(:configuration, config) do
      get "/backoffice/customers/#{@customer.id}", params: { return_to: @state }
      assert_response :success
      assert_equal "/backoffice/", main_link("Administration")
      assert_nil query(main_link("Edit"))["return_to"]
      assert_select ".raa-notice", text: /Some list settings/
    end
  end

  def test_selection_collection_review_job_and_cancel_keep_the_current_resource_list
    with_collection do
      state = { "page" => "2" }
      post "/backoffice/batch_customers/selections", params: { target_ids: [ @customer.id ], return_to: state }
      assert_response :see_other
      assert_equal state, query(response.location)["return_to"]
      follow_redirect!
      assert_response :success
      operation_link = css_select("main a").find { |node| node["href"].include?("operations/award") }["href"]
      assert_equal state, query(operation_link)["return_to"]
      get operation_link
      assert_response :success
      assert_hidden_state(state)
      selection = css_select("input[name=selection_ref]").first["value"]
      path = "/backoffice/batch_customers/operations/award"
      post "#{path}/preflight", params: { selection_ref: selection, return_to: state, input: { amount: "1", note: "Navigation retained" } }
      assert_response :success
      assert_hidden_state(state)
      post "#{path}/execute", params: { selection_ref: selection, return_to: state, intent_ref: intent, confirmed_input: css_select("input[name=confirmed_input]").first["value"] }
      assert_response :see_other
      job_path = URI(response.location).path
      assert_equal state, query(response.location)["return_to"]
      follow_redirect!
      assert_response :success
      assert_equal state, query(main_link("Batch customers"))
      assert_equal state, query(main_link("Refresh status"))["return_to"]
      cancel_form = css_select("form").find { |node| node["action"].end_with?("/cancel") }
      assert cancel_form
      assert_nil URI(cancel_form["action"]).query
      assert_hidden_state(state)
      post "#{job_path}/cancel", params: { return_to: state }
      assert_response :see_other
      assert_equal state, query(response.location)["return_to"]
      assert_equal "Alice", @customer.reload.name
    end
  end

  def test_member_operations_keep_navigation_through_review_and_execution
    with_operations do
      state = { "page" => "2" }
      path = "/backoffice/contract_customers/#{@customer.id}/operations/review"
      get path, params: { return_to: state }
      assert_response :success
      assert_hidden_state(state)
      post "#{path}/preflight", params: { return_to: state, expected_version: 0, input: { note: "Reviewed once" } }
      assert_response :success
      assert_hidden_state(state)
      post "#{path}/execute", params: { return_to: state, intent_ref: intent, confirmed_input: css_select("input[name=confirmed_input]").first["value"] }
      assert_response :see_other
      assert_equal state, query(response.location)["return_to"]
      assert_equal "Reviewed once", @customer.reload.name
    end
  end
end
