# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/essentials"

# The audit log across records, behind a per-resource view_audit_log? grant.
class AuditLogIntegrationTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include EssentialFixtures

  def setup
    reset_database
    reset_essentials
    post "/test/sign_in/1"
  end

  def audit(**attributes)
    RailsAiAdmin::AuditEvent.create!({ actor_ref: "raa:actor:TestActor:7", tenant_ref: "raa:tenant:TestTenant:1", resource_key: "articles",
      operation: "update", status: "succeeded", code: "OK", record_id: @article.id.to_s, correlation_ref: SecureRandom.uuid,
      origin: "ui", changed_fields: [ "title" ], created_at: Time.current }.merge(attributes))
  end

  def test_the_log_lists_granted_resources_for_this_tenant_with_filters
    audit
    audit(operation: "destroy", record_id: "999", changed_fields: [])
    audit(status: "rejected", code: "CONFLICT", changed_fields: [], actor_ref: "raa:actor:TestActor:1")
    audit(operation: "export", record_id: nil, changed_fields: %w[title secret_salary])
    audit(resource_key: "tags", changed_fields: [ "name" ])
    audit(tenant_ref: "raa:tenant:TestTenant:2", changed_fields: [ "views" ])
    with_essential_resources do
      get "/backoffice/"
      assert_select "nav a[href='/backoffice/audit']", text: "Audit log"
      get "/backoffice/audit"
      assert_response :success
      rows = css_select("table.raa-history tbody tr")
      assert_equal 4, rows.size, "other tenants and ungranted resources stay out"
      assert_includes rows[0].text, "Exported CSV"
      assert_includes rows[0].text, "Title; 1 other field"
      assert_select "td", text: "Article #999"
      assert_select "a[href='/backoffice/articles/999']", count: 0
      assert_select "a[href='/backoffice/articles/#{@article.id}']"
      get "/backoffice/audit", params: { status: "rejected" }
      assert_equal 1, css_select("table.raa-history tbody tr").size
      get "/backoffice/audit", params: { actor: "raa:actor:TestActor:7", operation: "update" }
      assert_equal 1, css_select("table.raa-history tbody tr").size
      assert_select "p.raa-notice", text: /Test Actor #7/
      get "/backoffice/audit", params: { resource: "tags" }
      assert_response :unprocessable_content
      get "/backoffice/audit", params: { before: "x" }
      assert_response :unprocessable_content
    end
  end

  def test_the_log_needs_a_grant
    EssentialFixtures::Policy.history = false
    with_essential_resources do
      get "/backoffice/"
      assert_select "a[href='/backoffice/audit']", count: 0
      get "/backoffice/audit"
      assert_response :not_found
    end
  end
end
