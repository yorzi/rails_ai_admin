# frozen_string_literal: true

require "test_helper"
require "support/application"

class SavedQueriesTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers

  def setup
    reset_database
    post "/test/sign_in/1"
  end

  def test_save_from_list_pin_open_and_remove
    get "/backoffice/customers", params: { q: "Al" }
    assert_response :success
    form = css_select("form[action='/backoffice/customers/reports']").first
    ast = form.at_css("[name=definition]")["value"]
    post "/backoffice/customers/reports", params: { definition: ast, name: "Matching customers", pinned: "1" }
    assert_response :see_other
    follow_redirect!
    assert_select "h2", "Matching customers"
    get "/backoffice"
    assert_select "h2", "Matching customers"
    assert_select "td a", "Alice"
    post "/test/sign_in/2"
    get "/backoffice"
    assert_select "h2", text: "Matching customers", count: 0
    post "/test/sign_in/1"
    delete "/backoffice/customers/reports/#{RailsAiAdmin::SavedQuery.sole.id}"
    assert_response :see_other
    assert_empty RailsAiAdmin::SavedQuery.all
  end

  def test_shared_metric_uses_current_viewers_filter_and_tenant
    TestPolicy.granted_filters = [ :active ]
    query = RailsAiAdmin::SavedQuery.create!(id: SecureRandom.uuid, name: "Active customers", actor_ref: context.actor_ref,
      tenant_ref: context.tenant_ref, resource_key: "customers", shared: true, pinned: true,
      query_ast: { kind: "metric", function: "count", group_by: "active" })
    post "/test/sign_in/2"
    get "/backoffice"
    assert_select "table caption", "Active customers"
    assert_select "p.raa-metric-value", "1"
    TestPolicy.granted_filters = []
    get "/backoffice"
    refute_includes response.body, "Active customers"
    assert_raises(RailsAiAdmin::AccessDenied) { RailsAiAdmin::Presentation::SavedQueries.evaluate(context(tenant: 2), query) }
  end

  def test_unknown_query_keys_and_unauthorized_sharing_are_rejected
    [ { definition: { kind: "metric", sql: "invalid" }.to_json }, { definition: { kind: "list" }.to_json, shared: "1" } ].each do |args|
      post "/backoffice/customers/reports", params: args.merge(name: "Report")
      assert_operator response.status, :>=, 400
      assert_empty RailsAiAdmin::SavedQuery.all
    end
  end
end
