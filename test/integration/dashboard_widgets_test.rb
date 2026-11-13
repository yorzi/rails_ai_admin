# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/essentials"

# Declared overview metrics and trends, through the list grants.
class DashboardWidgetsIntegrationTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include EssentialFixtures

  def setup
    reset_database
    reset_essentials
    Article.create!(account_id: 1, title: "Popular", views: 50, updated_at: 3.days.ago)
    Article.create!(account_id: 1, title: "Old", views: 1, updated_at: 40.days.ago)
    Article.create!(account_id: 2, title: "Other tenant", views: 99)
    post "/test/sign_in/1"
  end

  def test_metrics_and_a_trend_render_from_the_policy_relation
    with_essential_resources do
      get "/backoffice/"
      assert_response :success
      section = css_select("section.raa-dashboard-section").first
      assert section
      values = css_select(".raa-metrics li").map { |item| item.text.squish }
      assert_equal [ "3 Articles", "1 Articles: Popular" ], values
      assert_select ".raa-metrics a[href='/backoffice/articles?scope=popular']"
      assert_select "figure.raa-trend figcaption", text: /Updated articles — 2 in the last 14 days/
      assert_select "svg.raa-chart[aria-hidden=true] rect.raa-bar", count: 14
      assert_select "figure.raa-trend details table tbody tr", count: 14
    end
  end

  def test_ungranted_tabs_and_unreadable_fields_hide_their_widgets
    EssentialFixtures::Policy.scopes = []
    EssentialFixtures::Policy.read = %i[id title]
    with_essential_resources do
      get "/backoffice/"
      assert_equal [ "3 Articles" ], css_select(".raa-metrics li").map { |item| item.text.squish }
      assert_select "figure.raa-trend", count: 0
    end
  end

  def test_declarations_are_checked
    assert_raises(RailsAiAdmin::ConfigurationError) { RailsAiAdmin::Presentation::Dashboard::Builder.new.trend(:created_at, days: 3) }
    bad = Class.new(RailsAiAdmin::Resource) do
      model "Article"
      key :articles
      title :title
      fields { text :title }
      dashboard { trend :title }
    end
    assert_raises(RailsAiAdmin::ConfigurationError) { bad.validate! }
    missing = Class.new(RailsAiAdmin::Resource) do
      model "Article"
      key :articles
      title :title
      fields { text :title }
      dashboard { metric :busy, scope: :busy }
    end
    assert_raises(RailsAiAdmin::ConfigurationError) { missing.validate! }
  end
end
