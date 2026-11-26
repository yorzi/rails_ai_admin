# frozen_string_literal: true

require "test_helper"
require "support/application"
require "rails_ai_admin/prune"
require "support/essentials"
require "support/assistant"

class ImportDraftsTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include EssentialFixtures
  include AssistantHelpers

  class Articles < RailsAiAdmin::Resource
    model "Article"
    key :articles
    title :title
    fields do
      text :title, required: true, nullable: false, filterable: [ :eq ]
      integer :views
    end
  end

  class Policy < EssentialFixtures::Policy
    def allowed?(context:, action:, resource:, record: nil) = action == :create || super
    def assistant?(context:, resource:) = true

    def fields(context:, resource:, action:, record: nil)
      return [ :title ] if action == :filter
      super
    end
  end

  class SaveOnlyCheck < Article
    before_create { throw(:abort) if title == "Cannot save" }
  end

  class CheckedArticles < RailsAiAdmin::Resource
    model "ImportDraftsTest::SaveOnlyCheck"
    key :articles
    title :title
    fields { text :title, required: true }
  end

  def setup
    reset_database
    reset_essentials
    post "/test/sign_in/1"
  end

  def with_imports(&block) = with_essential_resources(resources: [ Articles.name ], policy: Policy.name, &block)

  def upload(text)
    file = Rack::Test::UploadedFile.new(StringIO.new(text), "text/csv", original_filename: "orders.csv")
    post "/backoffice/articles/imports", params: { mode: "review", file: file }
  end

  def digest = css_select("input[name=review_digest]").first["value"]

  def test_mapping_skips_visible_duplicates_and_confirms_only_the_reviewed_rows
    with_imports do
      Article.create!(account_id: 2, title: "海外")
      upload("Headline,Views\nFirst,5\n海外,7\n=SUM(1),3\n")
      assert_response :see_other
      path = response.location
      follow_redirect!
      assert_select "option[value=title]"
      assert_select "option[value=password]", count: 0
      assert_select "td", text: /formula/i
      patch path, params: { mapping: { "0" => "title", "1" => "views" }, match_field: "title", duplicates: "skip", excluded: [ "4" ], review_digest: digest }
      assert_response :success
      assert_select "td", text: /duplicate/i
      refute_includes RailsAiAdmin::ImportDraft.find(URI(path).path.split("/").last).payload_blob, "Headline"
      assert_equal 2, Article.count
      assert_empty RailsAiAdmin::OperationRun.all
      reviewed = digest
      2.times do
        post "#{path}/confirm", params: { review_digest: reviewed }
        assert_response :see_other
      end
      follow_redirect!
      assert_equal [ [ "First", 1 ], [ "海外", 7 ] ], Article.where(account_id: 1).order(:id).pluck(:title, :views)
      assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
      assert_nil RailsAiAdmin::ImportDraft.find(URI(path).path.split("/").last).payload_blob
    end
  end

  def test_confirmed_large_import_resumes_downloads_and_retries_only_failed_rows
    with_essential_resources(resources: [ CheckedArticles.name ], policy: Policy.name, context_adapter: "ImportDraftsTest::JobContext") do
      upload("Title\n" + (1..100).map { |i| "Batch #{i}\n" }.join + "Cannot save\n")
      assert_response :see_other
      path = response.location
      follow_redirect!
      token = digest
      2.times { post "#{path}/confirm", params: { review_digest: token } }
      draft = RailsAiAdmin::ImportDraft.sole
      assert_equal 101, draft.rows.count
      assert_equal 1, Article.count
      assert_nil draft.payload_blob
      assert RailsAiAdmin::Presentation::ImportBatch.process(draft.id)
      assert_equal 25, draft.reload.created_count
      4.times { RailsAiAdmin::Presentation::ImportBatch.process(draft.id) }
      assert_equal 100, draft.reload.created_count
      assert_equal 1, draft.rows.where(status: "failed").count
      assert_nil draft.rows.find_by!(status: "created").input_blob
      get "#{path}/failed"
      assert_response :success
      assert_includes response.body, "Cannot save"
      refute_includes response.body, "Batch 1"
      get path
      retry_token = css_select("form[action$='/retry'] input[name=review_digest]").first["value"]
      post "#{path}/retry", params: { review_digest: retry_token }
      assert_response :see_other
      RailsAiAdmin::Presentation::ImportBatch.process(draft.id)
      assert_equal 2, draft.rows.find_by!(number: 102).attempts
      assert_equal 100, draft.reload.created_count
      post "#{path}/retry", params: { review_digest: retry_token }
      assert_response :conflict
      post "/test/sign_in/2"
      get "#{path}/failed"
      assert_response :not_found
    end
  end

  class JobContext < TestContext
    def resolve_job(**args) = OperationJobContext.new.resolve_job(**args)
  end

  def test_failed_save_rolls_back_every_create_and_the_draft_claim
    with_essential_resources(resources: [ CheckedArticles.name ], policy: Policy.name) do
      upload("Title\nWould save\nCannot save\n")
      path = response.location
      follow_redirect!
      post "#{path}/confirm", params: { review_digest: digest }
      assert_response :conflict
      assert_equal [ "First" ], Article.pluck(:title)
      assert_empty RailsAiAdmin::AuditEvent.all
      assert_empty RailsAiAdmin::OperationRun.all
      get path
      assert_select "button[value=confirm]"
    end
  end

  def test_owner_epoch_import_grant_and_unsaved_changes_are_rechecked
    with_imports do
      upload("Title\nNew title\n")
      path = response.location
      follow_redirect!
      reviewed = digest
      post "#{path}/confirm", params: { review_digest: reviewed, mapping: { "0" => "" } }
      assert_response :conflict
      post "/test/sign_in/2"
      get path
      assert_response :not_found
      post "/test/sign_in/1"
      service = RailsAiAdmin::Presentation::ImportReview
      id = URI(path).path.split("/").last
      [ context(tenant: 2), context(version: "changed") ].each do |other|
        assert_raises(RailsAiAdmin::AccessDenied) { service.new(other, Articles).find!(id) }
      end
      EssentialFixtures::Policy.export = false
      post "#{path}/confirm", params: { review_digest: reviewed }
      assert_response :not_found
      assert_equal 1, Article.count
    end
  end

  def test_malformed_or_oversized_input_never_leaves_a_draft
    with_imports do
      [ "Title\n\xFF".b, "Title\n\"open", "Title\n" + "a\n" * 101 ].each do |text|
        assert_no_difference "RailsAiAdmin::ImportDraft.count" do
          upload(text)
          assert_response :unprocessable_content
        end
      end
    end
  end

  def test_optional_mapping_uses_only_headers_and_permitted_fields
    reset_assistant
    with_imports do
      upload("Headline,Ignore\nPRIVATE ROW CONTENT,do not send\n")
      path = response.location
      follow_redirect!
      assert_select "button", text: "Suggest column mapping with AI"
      LLMFixture.reply({ columns: [ { position: 1, field: "title", hint: "none" }, { position: 2, field: "password", hint: "none" } ] }.to_json)
      post "#{path}/suggest", params: { review_digest: digest }
      assert_response :success
      assert_select "select[name='mapping[0]'] option[selected][value=title]"
      assert_select "option[value=password]", count: 0
      assert_select "button[value=confirm]", count: 0
      request = LLMFixture.requests.sole
      assert_includes request.fetch("messages").to_json, "Headline"
      refute_includes request.to_json, "PRIVATE ROW CONTENT"
      assert_equal "json_schema", request.dig("response_format", "type")
      assert_empty Array(request["tools"])
      assert_equal 1, Article.count
      assert_empty RailsAiAdmin::OperationRun.all
    end
  end

  def test_assistant_can_be_disabled_without_blocking_a_native_review
    reset_assistant
    with_imports do
      RailsAiAdmin.configuration.assistant = false
      upload("Title\nNative import\n")
      path = response.location
      follow_redirect!
      assert_select "button", text: "Suggest column mapping with AI", count: 0
      token = digest
      post "#{path}/suggest", params: { review_digest: token }
      assert_response :not_found
      assert_empty LLMFixture.requests
      post path, params: { review_digest: token, mapping: { "0" => "title" }, decision: "confirm" }
      assert_response :see_other
      assert Article.exists?(title: "Native import")
    end
  end

  def test_mapping_budget_refusal_keeps_the_review_usable
    reset_assistant
    with_imports do
      RailsAiAdmin.configuration.assistant_daily_token_limit = 10
      chat = RailsAiAdmin::Assistant.create_chat!(context)
      RubyLLM::ActiveRecord::Usage.create!(chat: chat, owner: chat, operation: "chat", provider: "openai", model: "gpt-4.1-mini", status: "succeeded", input_tokens: 10)
      upload("Title\nNew record\n")
      path = response.location
      follow_redirect!
      post "#{path}/suggest", params: { review_digest: digest }
      assert_response :service_unavailable
      assert_select "[role=alert]", text: /map the columns manually/
      assert_select "button[value=confirm]"
      assert_empty LLMFixture.requests
      assert_empty RailsAiAdmin::OperationRun.all
    end
  end

  def test_chat_shows_a_live_preview_without_exposing_cells_to_the_provider
    reset_assistant
    with_imports do
      RailsAiAdmin.configuration.surfaces = true
      upload("Title\nPrivate article title\n")
      path = URI(response.location).path
      chat = RailsAiAdmin::Assistant.create_chat!(context)
      session = RailsAiAdmin::Assistant::Session.new(context: context, chat: chat, fence: -> { })
      tool = RailsAiAdmin::Assistant.tools_for(session).find { |entry| entry.class.tool_name == "preview_csv_import" }
      assert tool
      result = tool.execute(tool_call: Struct.new(:id).new(SecureRandom.uuid), resource: "articles")
      refute_includes result.to_json, "Private article"
      refute_includes result.to_json, "orders.csv"
      surface = "/backoffice/assistant/surfaces/#{result.fetch("surface")}"
      get surface
      assert_response :success
      assert_select "a[href=?]", path
      assert_select "p", text: /1 of 1 rows selected/
      assert_empty RailsAiAdmin::OperationRun.all
      post "/test/sign_in/2"
      get surface
      assert_response :not_found
      post "/test/sign_in/1"
      EssentialFixtures::Policy.export = false
      refute_includes RailsAiAdmin::Assistant.tools_for(session).map(&:name), "preview_csv_import"
      get surface
      assert_response :not_found
    end
  end

  def test_changed_duplicate_mapping_and_expired_draft_cannot_execute
    with_imports do
      upload("Title\nNew title\n")
      assert_response :see_other
      path = response.location
      follow_redirect!
      old = digest
      patch path, params: { mapping: { "0" => "password" }, review_digest: old }
      assert_response :unprocessable_content
      patch path, params: { mapping: { "0" => "title" }, match_field: "title", duplicates: "skip", review_digest: old }
      assert_response :success
      reviewed = digest
      post "#{path}/confirm", params: { review_digest: old }
      assert_response :conflict
      Article.create!(account_id: 1, title: "New title")
      post "#{path}/confirm", params: { review_digest: reviewed }
      assert_response :conflict
      travel 31.minutes do
        get path
        assert_response :not_found
        RailsAiAdmin::Prune.new.call
        refute RailsAiAdmin::ImportDraft.exists?(id: URI(path).path.split("/").last)
      end
      assert_equal 2, Article.count
      assert_empty RailsAiAdmin::AuditEvent.all
    end
  end
end
