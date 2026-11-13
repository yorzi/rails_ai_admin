# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/essentials"

# A record's change history: who, when and which fields, behind its own grant.
class HistoryIntegrationTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include EssentialFixtures

  def setup
    reset_database
    reset_essentials
    post "/test/sign_in/1"
  end

  def intent = css_select("input[name=intent_ref]").first["value"]

  def edit(params)
    get "/backoffice/articles/#{@article.id}/edit"
    patch "/backoffice/articles/#{@article.id}", params: { intent_ref: intent, record: params }
  end

  def audit(**attributes)
    RailsAiAdmin::AuditEvent.create!({ actor_ref: "raa:actor:TestActor:7", tenant_ref: "raa:tenant:TestTenant:1", resource_key: "articles",
      operation: "update", status: "succeeded", code: "OK", record_id: @article.id.to_s, correlation_ref: SecureRandom.uuid,
      origin: "ui", changed_fields: [ "title" ], created_at: Time.current }.merge(attributes))
  end

  def test_history_lists_changes_with_readable_field_labels_and_the_actor
    with_essential_resources do
      edit(title: "Second", views: "5")
      assert_response :see_other
      edit(password: "a long password")
      get "/backoffice/articles/#{@article.id}"
      assert_select "a[href='/backoffice/articles/#{@article.id}/history']", text: "History"
      get "/backoffice/articles/#{@article.id}/history"
      assert_response :success
      assert_select "h1", text: "History of Second"
      rows = css_select("table.raa-history tbody tr")
      assert_equal 2, rows.size
      assert_includes rows[0].text, "Password"
      assert_includes rows[1].text, "Updated"
      assert_includes rows[1].text, "Title, Views"
      assert_includes rows[1].text, "Test Actor #1"
      assert_includes rows[1].text, "(you)"
      assert_select "time[datetime]", count: 2
    end
  end

  def test_fields_the_actor_cannot_see_are_counted_not_named
    audit(changed_fields: %w[title secret_salary])
    EssentialFixtures::Policy.read = %i[id title]
    EssentialFixtures::Policy.write = []
    with_essential_resources do
      get "/backoffice/articles/#{@article.id}/history"
      assert_response :success
      assert_select "tbody td", text: "Title; 1 other field"
      refute_includes response.body, "secret_salary"
    end
  end

  def test_rejected_attempts_other_tenants_and_other_records_stay_apart
    audit(record_id: (@article.id + 1000).to_s)
    audit(tenant_ref: "raa:tenant:TestTenant:2", changed_fields: [ "views" ])
    with_essential_resources do
      get "/backoffice/articles/#{@article.id}/edit"
      ref = intent
      @article.update!(title: "Changed elsewhere")
      patch "/backoffice/articles/#{@article.id}", params: { intent_ref: ref, record: { title: "Mine" } }
      assert_response :conflict
      get "/backoffice/articles/#{@article.id}/history"
      rows = css_select("table.raa-history tbody tr")
      assert_equal 1, rows.size
      assert_includes rows[0].text, "Not saved"
      assert_includes rows[0].text, "CONFLICT"
    end
  end

  def test_the_page_needs_its_own_grant_and_show
    EssentialFixtures::Policy.history = false
    with_essential_resources do
      get "/backoffice/articles/#{@article.id}"
      assert_select "a[href$='/history']", count: 0
      get "/backoffice/articles/#{@article.id}/history"
      assert_response :not_found
      EssentialFixtures::Policy.history = true
      other = Article.create!(account_id: 2, title: "Other tenant")
      get "/backoffice/articles/#{other.id}/history"
      assert_response :not_found
      get "/backoffice/articles/#{@article.id}/history?before=abc"
      assert_response :unprocessable_content
    end
  end

  def test_older_changes_are_paged_and_hosts_can_name_actors
    55.times { |index| audit(changed_fields: [ "views" ], created_at: Time.current - (60 - index)) }
    labels = ->(context:, actor_refs:) { actor_refs.to_h { |ref| [ ref, "Ada Lovelace" ] } }
    TestContext.define_method(:actor_labels, &labels)
    with_essential_resources do
      get "/backoffice/articles/#{@article.id}/history"
      assert_equal 50, css_select("table.raa-history tbody tr").size
      assert_includes response.body, "Ada Lovelace"
      older = css_select("a").find { |node| node.text == "Show older changes" }
      assert older
      get older["href"]
      assert_response :success
      assert_equal 5, css_select("table.raa-history tbody tr").size
      assert_empty css_select("a").select { |node| node.text == "Show older changes" }
    end
  ensure
    TestContext.remove_method(:actor_labels) if TestContext.method_defined?(:actor_labels)
  end
end
