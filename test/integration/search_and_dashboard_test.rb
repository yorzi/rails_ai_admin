# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/essentials"

# The header search across resources and dashboard counts.
class SearchAndDashboardIntegrationTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include EssentialFixtures

  def setup
    reset_database
    reset_essentials
    Article.create!(account_id: 1, title: "Rails guide")
    Article.create!(account_id: 2, title: "Rails elsewhere")
    Tag.create!(account_id: 1, name: "Rails")
    6.times { |index| Tag.create!(account_id: 1, name: "Rails #{index}") }
    post "/test/sign_in/1"
  end

  def test_search_lists_matches_per_resource_through_each_resources_grants
    with_essential_resources do
      get "/backoffice/articles"
      assert_select "form.raa-global-search[action='/backoffice/search'] input[type=search][name=q]"
      get "/backoffice/search", params: { q: "rails" }
      assert_response :success
      assert_select "section h2", text: "Articles"
      assert_select "section h2", text: "Tags"
      assert_select "a[href='/backoffice/articles/#{Article.find_by!(title: 'Rails guide').id}']", text: "Rails guide"
      refute_includes response.body, "Rails elsewhere"
      assert_equal 5, css_select("#raa-search-tags + ul li").size
      assert_select "a[href='/backoffice/tags?q=rails']", text: "View all matches in Tags"
      assert_select "a[href='/backoffice/articles?q=rails']", text: "Open in Articles"
      get "/backoffice/search", params: { q: "zzz" }
      assert_select "p[role=status]", text: /Nothing matches/
      get "/backoffice/search", params: { q: { nested: "x" } }
      assert_response :unprocessable_content
    end
  end

  def test_dashboard_counts_resources_that_opt_into_counts
    counted = Class.new(EssentialFixtures::TagAdmin)
    with_essential_resources do
      get "/backoffice/"
      assert_response :success
      assert_select ".raa-card-count", count: 0
    end
    EssentialFixtures::TagAdmin.stub(:index, RailsAiAdmin::Presentation::IndexSettings.new(count: :exact)) do
      with_essential_resources do
        get "/backoffice/"
        assert_select "a[href='/backoffice/tags'] .raa-card-count", text: "7 records"
      end
    end
    assert counted
  end
end
