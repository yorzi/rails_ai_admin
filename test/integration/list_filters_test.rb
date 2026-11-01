# frozen_string_literal: true

require "test_helper"
require "support/application"

class ListFiltersTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers

  def setup
    reset_database
    post "/test/sign_in/1"
    @filter = { "points" => { "gte" => "5", "lte" => "20" }, "active" => { "eq" => "true" } }
  end

  def query(url) = Rack::Utils.parse_nested_query(URI(url).query)
  def main_link(text) = css_select("main a").find { |node| node.text == text }

  def test_ungranted_filters_render_no_form_and_revoked_hints_redirect
    get "/backoffice/customers"
    assert_response :success
    assert_select "form.raa-filters", count: 0
    get "/backoffice/customers", params: { q: "Alice", filter: { points: { gte: "1" } } }
    assert_response :see_other
    assert_equal({ "q" => "Alice" }, query(response.location))
    follow_redirect!
    assert_select ".raa-notice", text: /Some list settings/
  end

  def test_granted_filters_render_typed_inputs_and_narrow_the_list
    TestPolicy.granted_filters = %i[points active]
    Customer.create!(account_id: 1, name: "Ten", points: 10)
    Customer.create!(account_id: 1, name: "Thirty", points: 30)
    Customer.create!(account_id: 1, name: "Idle", points: 10, active: false)
    Customer.create!(account_id: 2, name: "Foreign", points: 10)
    get "/backoffice/customers", params: { filter: @filter, sort: "name", direction: "desc" }
    assert_response :success
    assert_select "form.raa-filters fieldset legend", text: "Filters"
    assert_select "label[for=raa-filter-points-gte]", text: "Points from"
    assert_select "input#raa-filter-points-gte[type=number][name='filter[points][gte]'][value='5']"
    assert_select "input#raa-filter-points-lte[name='filter[points][lte]'][value='20']"
    assert_select "select#raa-filter-active-eq[name='filter[active][eq]'] option[selected][value=true]", text: "Yes"
    assert_select "form.raa-filters input[type=hidden][name=sort][value=name]"
    assert_select "form.raa-filters input[type=hidden][name=page]", count: 0
    assert_select "form.raa-search input[type=hidden][name='filter[points][gte]'][value='5']"
    assert_select "input[type=hidden][id]", count: 0
    assert_equal [ "Ten" ], css_select("tbody tr").map { |row| row.text[/Ten|Thirty|Idle|Foreign|Alice/] }
    view = css_select("main a").find { |node| node.text.start_with?("View ") }
    assert_equal @filter, query(view["href"]).dig("return_to", "filter")
    assert_equal @filter, query(css_select("th a").find { |node| node.text == "Name" }["href"])["filter"]
    clear = main_link("Clear filters")
    assert_equal({ "sort" => "name", "direction" => "desc" }, query(clear["href"]))

    get view["href"]
    get main_link("Edit")["href"]
    assert_select "input[name='return_to[filter][points][gte]'][value='5']"
    assert_select "input[name='return_to[filter][active][eq]'][value='true']"
    ref = css_select("input[name=intent_ref]").first["value"]
    patch "/backoffice/customers/#{Customer.find_by!(name: "Ten").id}", params: { intent_ref: ref, return_to: { filter: @filter }, record: { name: "Ten edited" } }
    assert_response :see_other
    assert_equal @filter, query(response.location).dig("return_to", "filter")
    follow_redirect!
    assert_equal @filter, query(main_link("Customers")["href"])["filter"]
  end

  def test_blank_inputs_are_ignored_and_bad_values_or_undeclared_filters_are_invalid
    TestPolicy.granted_filters = %i[points active name]
    get "/backoffice/customers", params: { sort: "name", filter: { points: { gte: "", lte: "" }, active: { eq: "" } } }
    assert_response :see_other
    assert_equal({ "sort" => "name" }, query(response.location))
    get "/backoffice/customers", params: { filter: { points: { gte: "3", lte: "" }, active: { eq: "" } } }
    assert_response :see_other
    assert_equal({ "filter" => { "points" => { "gte" => "3" } } }, query(response.location))
    follow_redirect!
    assert_response :success
    assert_select ".raa-notice", count: 0
    get "/backoffice/customers", params: { filter: { active: { eq: "true" }, points: { gte: "3" } } }
    assert_response :success, "canonical conditions in a different key order are not redirected again"
    [ { points: { gte: "abc" } }, { active: { eq: "maybe" } }, { name: { eq: "Alice" } }, { points: { eq: "1" } }, { points: "1" } ].each do |filter|
      get "/backoffice/customers", params: { filter: filter }
      assert_response :unprocessable_content
    end
  end
end
