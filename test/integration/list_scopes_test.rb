# frozen_string_literal: true

require "test_helper"
require "support/application"

class ListScopesTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers

  def setup
    reset_database
    post "/test/sign_in/1"
  end

  def query(url) = Rack::Utils.parse_nested_query(URI(url).query)
  def scope_links = css_select("nav.raa-scopes a")
  def scope_link(text) = scope_links.find { |node| node.text == text }

  def test_ungranted_scopes_render_nothing_and_the_list_keeps_the_policy_relation
    Customer.create!(account_id: 1, name: "Inactive", active: false)
    get "/backoffice/customers"
    assert_response :success
    assert_select "nav.raa-scopes", count: 0
    assert_includes response.body, "Inactive"
    get "/backoffice/customers", params: { scope: "active" }
    assert_response :see_other
    follow_redirect!
    assert_select ".raa-notice", text: /Some list settings/
  end

  def test_granted_tabs_mark_the_current_scope_and_carry_list_state
    TestPolicy.granted_scopes = %i[active rewarded all]
    Customer.create!(account_id: 1, name: "Alicia", active: false, points: 4)
    Customer.create!(account_id: 2, name: "Alien foreign", points: 9)
    get "/backoffice/customers", params: { q: "Ali", sort: "name", direction: "desc", page: "1" }
    assert_response :success
    assert_equal [ "Active", "Rewarded", "All customers" ], scope_links.map(&:text)
    assert_select "nav.raa-scopes[aria-label='Customers scopes']"
    assert_select "nav.raa-scopes a[aria-current=true]", text: "Active"
    assert_includes response.body, "Alice"
    refute_includes response.body, "Alicia"
    assert_equal({ "q" => "Ali", "sort" => "name", "direction" => "desc" }, query(scope_link("Active")["href"]))
    assert_equal({ "q" => "Ali", "sort" => "name", "direction" => "desc", "scope" => "rewarded" }, query(scope_link("Rewarded")["href"]))

    get scope_link("Rewarded")["href"]
    assert_response :success
    assert_select "nav.raa-scopes a[aria-current=true]", text: "Rewarded"
    assert_includes response.body, "Alicia"
    refute_includes response.body, "Alien foreign"
    assert_select "form.raa-search input[name=scope][value=rewarded]"
    view = css_select("main a.raa-row-title").first
    assert_equal "rewarded", query(view["href"]).dig("return_to", "scope")
    sort = css_select("th a").find { |node| node.text == "Name" }
    assert_equal "rewarded", query(sort["href"])["scope"]

    get view["href"]
    assert_response :success
    back = css_select("main a").find { |node| node.text == "Customers" }
    assert_equal "rewarded", query(back["href"])["scope"]
  end

  def test_default_scope_url_is_canonical_and_revocation_resets_to_current_grants
    TestPolicy.granted_scopes = %i[active rewarded]
    get "/backoffice/customers", params: { scope: "active", page: "1" }
    assert_response :success
    get "/backoffice/customers", params: { scope: "rewarded" }
    assert_response :success
    TestPolicy.granted_scopes = %i[active]
    get "/backoffice/customers", params: { q: "Alice", scope: "rewarded", page: "2" }
    assert_response :see_other
    assert_equal({ "q" => "Alice" }, query(response.location))
  end

  def test_undeclared_or_malformed_scopes_are_invalid_queries
    TestPolicy.granted_scopes = %i[active rewarded all]
    [ "missing", "all; DROP TABLE customers", "ALL" ].each do |scope|
      get "/backoffice/customers", params: { scope: scope }
      assert_response :unprocessable_content
    end
    assert Customer.exists?(@customer.id)
  end
end
