# frozen_string_literal: true

require "test_helper"
require "support/application"
require "minitest/mock"
require "support/index_resources"

class IndexTableTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers

  def setup
    reset_database
    post "/test/sign_in/1"
  end

  def with_indexed_resource(&block)
    RailsAiAdmin.stub(:registry, RailsAiAdmin::Registry.new([ "TestResource", "IndexedCustomerAdmin" ]), &block)
  end

  def query(url) = Rack::Utils.parse_nested_query(URI(url).query)
  def headers = css_select("thead th").map { |node| node.text.strip }

  def test_declared_columns_default_sort_page_size_and_count_render
    12.times { |index| Customer.create!(account_id: 1, name: "Row #{index.to_s.rjust(2, "0")}", points: index) }
    with_indexed_resource do
      get "/backoffice/indexed_customers"
      assert_response :success
      assert_equal [ "Points", "Name", "Actions" ], headers
      assert_select "th[aria-sort=descending] a", text: "Name"
      assert_select "thead th a", text: "Points", count: 0, message: "declared sortable but not granted"
      assert_select "tbody tr", count: 10
      assert_select "tbody tr:first-child td.raa-cell-compact", count: 1, message: "the integer column stays on one line"
      assert_select "p.raa-count", text: "13 matching records"
      assert_includes css_select("tbody tr").first.text, "Row 11"
      refute_includes response.body, "never show"
      name_link = css_select("th a").find { |node| node.text == "Name" }["href"]
      assert_equal({ "sort" => "name", "direction" => "asc" }, query(name_link))
      next_link = css_select("nav.raa-pagination a").find { |node| node.text == "Next" }["href"]
      assert_equal({ "page" => "2" }, query(next_link), "the default order stays implicit")
      get next_link
      assert_select "tbody tr", count: 3
      get "/backoffice/indexed_customers", params: { sort: "name", direction: "desc" }
      assert_response :success
      assert_select "th[aria-sort=descending] a", text: "Name"
      TestPolicy.hide_name = true
      get "/backoffice/indexed_customers"
      assert_response :success
      assert_select "th[aria-sort=descending]", count: 0
      assert_equal [ "Points", "Actions" ], headers
    end
  end

  def test_an_exact_count_shows_numbered_pages_with_the_current_one_marked
    68.times { |index| Customer.create!(account_id: 1, name: "Row #{index.to_s.rjust(2, "0")}", points: index) }
    with_indexed_resource do
      get "/backoffice/indexed_customers"
      assert_select "p.raa-count", text: "69 matching records"
      assert_select "nav.raa-pagination ol.raa-page-numbers" do
        assert_select "span[aria-current=page]", text: "Page 1"
        assert_equal %w[2 3 7], css_select("nav.raa-pagination ol a").map { |node| node.text.strip }
        assert_select "li[aria-hidden=true]", text: "…", count: 1
      end
      assert_select "nav.raa-pagination a[rel=prev]", count: 0
      get "/backoffice/indexed_customers", params: { page: "5" }
      assert_equal %w[1 2 3 4 6 7], css_select("nav.raa-pagination ol a").map { |node| node.text.strip }
      assert_select "nav.raa-pagination li[aria-hidden]", count: 0, message: "a one-page gap shows that page instead of …"
      assert_select "a[rel=prev][href*='page=4']", text: "Previous"
      assert_select "a[rel=next][href*='page=6']", text: "Next"
      last = css_select("nav.raa-pagination ol a").find { |node| node.text.strip == "7" }
      assert_equal "Page 7", last["aria-label"]
      assert_equal({ "page" => "7" }, query(last["href"]))
      get "/backoffice/indexed_customers", params: { page: "7" }
      assert_select "tbody tr", count: 9
      assert_select "a[rel=next]", count: 0
    end
  end

  def test_one_page_lists_have_no_pagination
    with_indexed_resource do
      get "/backoffice/indexed_customers"
      assert_select "nav.raa-pagination", count: 0
    end
  end

  def test_contains_and_blank_filters_render_and_narrow_the_list
    Customer.create!(account_id: 1, name: "Ada Lovelace", points: 3)
    Customer.create!(account_id: 1, name: "Grace Hopper", points: nil)
    TestPolicy.granted_filters = %i[name points]
    RailsAiAdmin.stub(:registry, RailsAiAdmin::Registry.new([ "TestResource", "PartlyFilteredCustomerAdmin" ])) do
      get "/backoffice/partly_filtered_customers"
      assert_select "label[for=raa-filter-name-contains]", text: "Name contains"
      assert_select "input#raa-filter-name-contains[type=text][name='filter[name][contains]']"
      assert_select "label[for=raa-filter-points-blank]", text: "Points is"
      assert_select "select#raa-filter-points-blank option", count: 3
      assert_select "select#raa-filter-points-blank option[value=true]", text: "Empty"
      assert_select "select#raa-filter-points-blank option[value=false]", text: "Not empty"
      get "/backoffice/partly_filtered_customers", params: { filter: { name: { contains: "LOVE", blank: "" }, points: { gte: "", blank: "" } } }
      assert_response :see_other, "blank inputs are dropped from the shared address"
      assert_equal({ "filter" => { "name" => { "contains" => "LOVE" } } }, Rack::Utils.parse_nested_query(URI(response.location).query))
      follow_redirect!
      assert_select "tbody .raa-row-title", text: "Ada Lovelace"
      assert_select "tbody tr", count: 1
      get "/backoffice/partly_filtered_customers", params: { filter: { points: { blank: "true" } } }
      assert_select "tbody .raa-row-title", text: "Grace Hopper"
      assert_select "tbody tr", count: 1
      assert_select "select#raa-filter-points-blank option[selected][value=true]"
    end
  end

  def test_any_of_filters_render_checkboxes_and_keep_the_list_in_links
    [ "Ada Lovelace", "Grace Hopper", "Linus Torvalds" ].each { |name| Customer.create!(account_id: 1, name: name) }
    TestPolicy.granted_filters = %i[name]
    RailsAiAdmin.stub(:registry, RailsAiAdmin::Registry.new([ "TestResource", "ChoiceFilteredCustomerAdmin" ])) do
      get "/backoffice/choice_filtered_customers"
      assert_select "fieldset.raa-filter-choices legend", text: "Name is any of"
      assert_select "fieldset.raa-filter-choices input[type=checkbox][name='filter[name][in][]']", count: 3
      assert_select "label[for=raa-filter-name-in-1]", text: "Grace"
      get "/backoffice/choice_filtered_customers", params: { filter: { name: { in: [ "Ada Lovelace", "Linus Torvalds" ] } } }
      assert_response :success
      assert_equal %w[Ada Linus], css_select("tbody .raa-row-title").map { |node| node.text.strip }.sort
      assert_select "input#raa-filter-name-in-0[checked]"
      assert_select "input#raa-filter-name-in-1:not([checked])"
      record = css_select("tbody .raa-row-title").first["href"]
      assert_equal({ "return_to" => { "filter" => { "name" => { "in" => [ "Ada Lovelace", "Linus Torvalds" ] } } } }, query(record))
      get record
      assert_select "a[href='/backoffice/choice_filtered_customers?#{ { filter: { name: { in: [ "Ada Lovelace", "Linus Torvalds" ] } } }.to_query }']"
      get "/backoffice/choice_filtered_customers", params: { filter: { name: { in: [ "Unknown" ] } } }
      assert_response :unprocessable_content
    end
  end
end
