# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/essentials"

# CSV export of the current list behind its own grant.
class CsvExportIntegrationTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include EssentialFixtures

  def setup
    reset_database
    reset_essentials
    @article.update!(contact: "ada@example.com", settings: { "a" => 1 }, password: "stored password")
    Article.create!(account_id: 1, title: "=HYPERLINK(\"http://evil\")", views: -3)
    Article.create!(account_id: 1, title: "Quote \"me\", please", views: 7)
    Article.create!(account_id: 2, title: "Other tenant", views: 9)
    post "/test/sign_in/1"
  end

  def rows = response.body.delete_prefix("﻿").split("\r\n")

  def test_the_list_exports_with_its_grants_and_is_audited
    with_essential_resources do
      get "/backoffice/articles"
      assert_select "form[action='/backoffice/articles/exports'][data-turbo=false] input[type=submit][value='Export CSV']"
      post "/backoffice/articles/exports", params: { sort: "title", direction: "asc" }
      assert_response :success
      assert_equal "text/csv; charset=utf-8", response.media_type + "; charset=" + response.charset
      assert_match(/attachment; filename="articles-\d{8}-\d{4}\.csv"/, response.headers["Content-Disposition"])
      assert_includes response.headers["Cache-Control"], "no-store"
      assert_equal %("Id","Title","Views","Contact","Website","Opens at","Settings","Tags","Updated at"), rows.first
      assert_equal 4, rows.size
      # Title order depends on the database collation (punctuation may be
      # ignored), so rows are matched by content.
      data = rows.drop(1)
      assert data.any? { |row| row.include?(%("'=HYPERLINK(""http://evil"")","-3")) }, "formula text is neutralized"
      assert data.any? { |row| row.include?(%("First","1","ada@example.com","","","{""a"":1}")) }
      assert data.any? { |row| row.include?(%("Quote ""me"", please","7")) }
      refute_includes response.body, "Other tenant"
      refute_includes response.body, @article.password_digest
      audit = RailsAiAdmin::AuditEvent.last
      assert_equal [ "export", "succeeded", "articles" ], [ audit.operation, audit.status, audit.resource_key ]
      assert_includes audit.changed_fields, "title"
    end
  end

  def test_search_filters_and_read_grants_shape_the_file
    EssentialFixtures::Policy.read = %i[id title views]
    with_essential_resources do
      post "/backoffice/articles/exports", params: { q: "quote", filter: { views: { gte: "5" } } }
      assert_response :success
      assert_equal [ %("Id","Title","Views"), %("#{Article.find_by!(views: 7).id}","Quote ""me"", please","7") ], rows
    end
  end

  def test_export_needs_its_grant_csrf_and_a_bounded_list
    EssentialFixtures::Policy.export = false
    with_essential_resources do
      get "/backoffice/articles"
      assert_select "form.raa-export", count: 0
      post "/backoffice/articles/exports"
      assert_response :not_found
      EssentialFixtures::Policy.export = true
    end
    with_essential_resources(export_limit: 2) do
      post "/backoffice/articles/exports"
      assert_response :see_other
      follow_redirect!
      assert_select ".raa-notice, [role=status]", text: /more than 2 records/
    end
    with_essential_resources do
      post "/backoffice/articles/exports", params: { page: "2" }
      assert_response :success
      post "/backoffice/articles/exports", params: { sort: "views" }
      assert_response :unprocessable_content
    end
    assert_raises(RailsAiAdmin::ConfigurationError) do
      config = RailsAiAdmin::Configuration.new
      config.export_limit = 0
      config.finalize!
    end
  end
end
