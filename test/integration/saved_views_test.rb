# frozen_string_literal: true

require "test_helper"
require "support/application"
require "minitest/mock"
require "support/index_resources"

# Named list settings that belong to one person and never widen access.
class SavedViewsTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers

  def setup
    reset_database
    post "/test/sign_in/1"
  end

  def with_resources(&block)
    RailsAiAdmin.stub(:registry, RailsAiAdmin::Registry.new([ "TestResource", "IndexedCustomerAdmin" ]), &block)
  end

  def save(name, return_to)
    post "/backoffice/indexed_customers/views", params: { name: name, return_to: return_to }
  end

  def test_a_person_saves_opens_replaces_and_deletes_a_view
    Customer.create!(account_id: 1, name: "Bob", points: 7)
    with_resources do
      get "/backoffice/indexed_customers"
      assert_select "details.raa-saved-views:not([open]) summary", text: "Saved views"
      assert_select "form.raa-save-view input#raa-saved-view-name[maxlength='80'][required]"
      save("  By   name ", { q: "B", sort: "name", direction: "asc", page: "2" })
      assert_response :see_other
      assert_equal({ "q" => "B", "sort" => "name" }, Rack::Utils.parse_nested_query(URI(response.location).query), "the page is not saved")
      follow_redirect!
      assert_select "[role=status], .raa-notice", text: /Saved the view "By name"/
      assert_select "details.raa-saved-views[open] summary", text: "Saved views (1)"
      assert_select ".raa-saved-view-list a[aria-current=true]", text: "By name"
      view = RailsAiAdmin::SavedView.sole
      assert_equal [ "By name", "indexed_customers" ], [ view.name, view.resource_key ]
      save("By name", { q: "Al" })
      assert_equal 1, RailsAiAdmin::SavedView.count, "the same name replaces the view"
      assert_equal({ "q" => "Al" }, JSON.parse(view.reload.state))
      get "/backoffice/indexed_customers"
      assert_select ".raa-saved-view-list a[href='/backoffice/indexed_customers?q=Al']", text: "By name"
      assert_select ".raa-saved-view-list a[aria-current]", count: 0
      delete "/backoffice/indexed_customers/views/#{view.id}", params: { return_to: { q: "Al" } }
      assert_response :see_other
      assert_equal "/backoffice/indexed_customers?q=Al", URI(response.location).request_uri
      assert_equal 0, RailsAiAdmin::SavedView.count
    end
  end

  def test_names_and_counts_are_bounded
    with_resources do
      [ "", "   ", "x" * 81, "bad\u0007name" ].each do |name|
        save(name, { q: "A" })
        assert_response :see_other
        follow_redirect!
        assert_select ".raa-notice", text: /Name the view with 1 to 80 characters/
      end
      20.times { |index| save("View #{index}", { q: "A" }) }
      save("One more", { q: "A" })
      follow_redirect!
      assert_select ".raa-notice", text: /up to 20 saved views/
      assert_equal 20, RailsAiAdmin::SavedView.count
      save("View 3", { q: "B" })
      assert_equal 20, RailsAiAdmin::SavedView.count, "replacing a name stays within the limit"
    end
  end

  def test_views_are_private_and_rechecked_against_current_grants
    with_resources do
      save("Sorted", { sort: "name", direction: "asc", q: "A" })
      own = RailsAiAdmin::SavedView.sole
      post "/test/sign_in/2"
      get "/backoffice/indexed_customers"
      assert_select ".raa-saved-view-list", count: 0, message: "another person's views are not listed"
      delete "/backoffice/indexed_customers/views/#{own.id}"
      assert_response :not_found
      assert_equal 1, RailsAiAdmin::SavedView.count
      post "/test/sign_in/1"
      TestPolicy.hide_name = true
      get "/backoffice/indexed_customers"
      link = css_select(".raa-saved-view-list a").first
      refute_includes link["href"], "sort=name", "a revoked sort grant drops out of the saved link"
    end
  end

  def test_the_panel_is_absent_without_the_table_and_saving_is_refused
    RailsAiAdmin::Navigation::SavedViews.stub(:available?, false) do
      with_resources do
        get "/backoffice/indexed_customers"
        assert_select "details.raa-saved-views", count: 0
        save("Nope", { q: "A" })
        assert_response :not_found
      end
    end
  end
end
