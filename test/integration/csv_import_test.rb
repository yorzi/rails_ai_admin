# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/essentials"

# CSV import: check, then create one audited record per row.
class CsvImportIntegrationTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include EssentialFixtures

  class ValidatedArticle < Article
    validates :views, numericality: { greater_than_or_equal_to: 0 }
    before_validation do
      Article.create!(account_id: account_id, title: "Validation side effect") if title == "Writes during validation"
    end
  end

  class ValidatedArticleAdmin < RailsAiAdmin::Resource
    model "CsvImportIntegrationTest::ValidatedArticle"
    key :articles
    title :title
    fields do
      id :id
      text :title, required: true
      integer :views
    end
  end

  class ValidationPolicy < EssentialFixtures::Policy
    def allowed?(context:, action:, resource:, record: nil)
      return false if action == :create && record&.title == "Outside create policy"
      super
    end
  end

  class AliasedArticleAdmin < RailsAiAdmin::Resource
    model "Article"
    key :articles
    title :title
    fields do
      id :id
      text :title, label: "Views", required: true
      integer :views, label: "View count"
    end
  end

  def setup
    reset_database
    reset_essentials
    post "/test/sign_in/1"
  end

  def csv(text) = Rack::Test::UploadedFile.new(StringIO.new(text), "text/csv", original_filename: "articles.csv")

  FILE = %(﻿Title,Views,Contact,Opens at,Unknown\r\n"Quoted, title",3,ada@example.com,09:30,x\r\n"Multi\nline ""quote""",4,,,\r\nBad views,many,,,\r\n,5,,,\r\n)

  def test_check_then_import_creates_valid_rows_and_reports_the_rest
    with_essential_resources do
      get "/backoffice/articles"
      assert_select "a[href='/backoffice/articles/imports/new']", text: "Import CSV"
      get "/backoffice/articles/imports/new"
      assert_response :success
      get "/backoffice/articles/imports/template"
      assert_includes response.body, %("Title","Views","Contact","Website","Opens at","Settings")
      refute_includes response.body, "Password"

      post "/backoffice/articles/imports", params: { mode: "check", file: csv(FILE) }
      assert_response :unprocessable_content
      assert_select "p[role=status]", text: "1 of 4 rows can be imported."
      assert_select "td", text: /Title contains control characters/, message: "the quoted line break stays in its cell"
      assert_select "p", text: /Ignored columns: Unknown/
      assert_select "td", text: "4"
      assert_select "td", text: /Views must be an integer/
      assert_select "td", text: /Title/
      assert_equal 1, Article.count, "a check writes nothing"

      post "/backoffice/articles/imports", params: { mode: "import", file: csv(FILE) }
      assert_select "p[role=status]", text: "Created 1 of 4 records."
      created = Article.where.not(id: @article.id).order(:id)
      assert_equal [ "Quoted, title" ], created.map(&:title)
      assert_equal "09:30", created.first.opens_at.strftime("%H:%M")
      assert_equal 1, RailsAiAdmin::AuditEvent.where(operation: "create", status: "succeeded").count
    end
  end

  def test_exported_files_import_back_and_bad_files_are_explained
    with_essential_resources do
      post "/backoffice/articles/exports"
      exported = response.body
      post "/backoffice/articles/imports", params: { mode: "check", file: csv(exported) }
      assert_response :success
      assert_select "p[role=status]", text: "1 of 1 rows can be imported."
      post "/backoffice/articles/imports", params: { mode: "check", file: csv("Nothing,Here\r\n1,2\r\n") }
      assert_select "p[role=alert]", text: /No column matches/
      post "/backoffice/articles/imports", params: { mode: "check", file: csv(%(Title\r\n"open)) }
      assert_select "p[role=alert]", text: /never closed/
      post "/backoffice/articles/imports", params: { mode: "check" }
      assert_select "p[role=alert]", text: "Choose a CSV file."
      post "/backoffice/articles/imports", params: { mode: "drop", file: csv(FILE) }
      assert_response :unprocessable_content
    end
    with_essential_resources(import_limit: 2) do
      post "/backoffice/articles/imports", params: { mode: "check", file: csv(FILE) }
      assert_select "p[role=alert]", text: /more than 2 rows/
    end
  end

  def test_check_applies_model_validation_and_create_policy_to_the_populated_record
    with_essential_resources(resources: [ ValidatedArticleAdmin.name ], policy: ValidationPolicy.name) do
      contents = "Title,Views\nValid,3\nNegative views,-1\nOutside create policy,8\n"
      post "/backoffice/articles/imports", params: { mode: "check", file: csv(contents) }
      assert_response :unprocessable_content
      assert_select "p[role=status]", text: "1 of 3 rows can be imported."
      assert_select "td", text: /Views must be greater than or equal to 0/
      assert_select "td", text: /The record is not available/
      assert_equal [ "First" ], Article.pluck(:title)
      assert_empty RailsAiAdmin::OperationRun.all
      assert_empty RailsAiAdmin::AuditEvent.all

      post "/backoffice/articles/imports", params: { mode: "import", file: csv(contents) }
      assert_select "p[role=status]", text: "Created 1 of 3 records."
      assert_equal %w[First Valid], Article.order(:id).pluck(:title)
    end
  end

  def test_check_never_runs_database_writes_from_model_validation
    with_essential_resources(resources: [ ValidatedArticleAdmin.name ], policy: ValidationPolicy.name) do
      post "/backoffice/articles/imports", params: { mode: "check", file: csv("Title\nWrites during validation\n") }
      assert_response :unprocessable_content
      assert_select "p[role=status]", text: "0 of 1 rows can be imported."
      assert_equal [ "First" ], Article.pluck(:title)
      assert_empty RailsAiAdmin::OperationRun.all
      assert_empty RailsAiAdmin::AuditEvent.all
    end
  end

  def test_malformed_quoting_rejects_the_whole_file_before_creating_any_rows
    with_essential_resources do
      [ %q("Quoted"suffix), %q(Unquoted"quote) ].each do |title|
        post "/backoffice/articles/imports", params: { mode: "import", file: csv("Title,Views\r\nValid,1\r\n#{title},2\r\n") }
        assert_response :unprocessable_content
        assert_select "p[role=alert]", text: /invalid quotation marks/
        assert_equal [ "First" ], Article.pluck(:title)
        assert_empty RailsAiAdmin::OperationRun.all
        assert_empty RailsAiAdmin::AuditEvent.all
      end
    end
  end

  def test_utf8_quoted_cells_and_carriage_return_line_endings
    with_essential_resources do
      post "/backoffice/articles/imports", params: { mode: "import", file: csv(%(Title,Views\r"中文 ""引号"", 示例",2\r"无换行结尾",3)) }
      assert_response :success
      assert_equal [ [ %(中文 "引号", 示例), 2 ], [ "无换行结尾", 3 ] ], Article.where.not(id: @article.id).order(:id).pluck(:title, :views)
    end
  end

  def test_template_distinguishes_labels_that_overlap_field_names
    with_essential_resources(resources: [ AliasedArticleAdmin.name ]) do
      get "/backoffice/articles/imports/template"
      assert_includes response.body, %("title","View count")
      post "/backoffice/articles/imports", params: { mode: "import", file: csv(response.body + "New article,7\r\n") }
      assert_response :success
      assert_equal [ "New article", 7 ], Article.where.not(id: @article.id).pick(:title, :views)
    end
  end

  def test_ambiguous_headers_do_not_import_into_an_arbitrary_field
    with_essential_resources(resources: [ AliasedArticleAdmin.name ]) do
      post "/backoffice/articles/imports", params: { mode: "import", file: csv("title,Views\nNew article,5\n") }
      assert_response :unprocessable_content
      assert_select "p[role=alert]", text: /A column matches more than one field/
      assert_equal [ "First" ], Article.pluck(:title)

      post "/backoffice/articles/imports", params: { mode: "import", file: csv("title,views\nNew article,5\n") }
      assert_response :success
      assert_equal [ "New article", 5 ], Article.where.not(id: @article.id).pick(:title, :views)
    end
  end

  def test_import_needs_its_grant_and_the_create_grant
    EssentialFixtures::Policy.export = false
    with_essential_resources do
      get "/backoffice/articles"
      assert_select "a[href$='/imports/new']", count: 0
      get "/backoffice/articles/imports/new"
      assert_response :not_found
    end
    EssentialFixtures::Policy.export = true
    post "/test/sign_in/2"
    with_essential_resources do
      post "/backoffice/articles/imports", params: { mode: "import", file: csv(FILE) }
      assert_response :not_found
    end
    assert_equal 1, Article.count
  end
end
