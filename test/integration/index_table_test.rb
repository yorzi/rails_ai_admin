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
end
