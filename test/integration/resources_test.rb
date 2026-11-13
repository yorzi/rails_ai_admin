# frozen_string_literal: true

require "test_helper"
require "support/application"

class ResourcesTest < ActionDispatch::IntegrationTest
  include DatabaseHelpers

  def setup
    reset_database
    post "/test/sign_in/1"
  end

  def intent_from_form
    css_select("input[name=intent_ref]").first["value"]
  end

  def test_anonymous_context_is_closed
    session = open_session
    session.get "/backoffice/customers"
    assert_equal 401, session.response.status
    refute_includes session.response.body, "Alice"
  end

  def test_index_show_and_cross_tenant_scoping_with_custom_mount
    get "/backoffice/customers"
    assert_response :success
    assert_includes response.body, "Alice"
    refute_includes response.body, "Other tenant"
    refute_includes response.body, "never show"
    assert_includes response.headers["Cache-Control"], "no-store"
    get "/backoffice/customers/#{@other.id}"
    assert_response :not_found
    other_body = response.body
    get "/backoffice/unregistered/#{@customer.id}"
    assert_response :not_found
    assert_equal other_body, response.body
  end

  def test_form_update_uses_intent_and_returns_303
    get "/backoffice/customers/#{@customer.id}/edit"
    assert_response :success
    token = intent_from_form
    patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: token, record: { name: "Edited", active: "false", points: "0" } }
    assert_response :see_other
    assert_equal "Edited", @customer.reload.name
    refute @customer.active
    assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
    patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: token, record: { name: "Edited", active: "false", points: "0" } }
    assert_response :see_other
    assert_equal 1, @customer.reload.lock_version
  end

  def test_validation_keeps_input_and_does_not_mutate
    get "/backoffice/customers/#{@customer.id}/edit"
    token = intent_from_form
    patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: token, record: { name: "", points: "08" } }
    assert_response :unprocessable_content
    assert_select "input[name='record[points]'][value='08']"
    assert_equal "Alice", @customer.reload.name
    assert_equal token, intent_from_form
  end

  def test_foreign_intent_action_and_target_do_not_execute
    get "/backoffice/customers/#{@customer.id}/edit"
    token = intent_from_form
    delete "/backoffice/customers/#{@customer.id}", params: { intent_ref: token }
    assert_response :not_found
    assert Customer.exists?(@customer.id)
    patch "/backoffice/customers/#{@other.id}", params: { intent_ref: token, record: { name: "Attack" } }
    assert_response :not_found
    assert_equal "Other tenant", @other.reload.name
  end

  def test_low_privilege_actor_cannot_write_by_direct_http
    post "/test/sign_in/2"
    get "/backoffice/customers/#{@customer.id}/edit"
    assert_response :not_found
    patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: "invented", record: { name: "Attack" } }
    assert_response :not_found
    assert_equal "Alice", @customer.reload.name
  end

  def test_record_text_is_escaped
    @customer.update!(name: '<script>alert("xss")</script>')
    get "/backoffice/customers/#{@customer.id}"
    assert_response :success
    refute_includes response.body, '<script>alert("xss")</script>'
    assert_includes response.body, "&lt;script&gt;"
  end

  def test_csrf_failure_has_no_side_effect
    get "/backoffice/customers/#{@customer.id}/edit"
    token = intent_from_form
    previous = RailsAiAdmin::ApplicationController.allow_forgery_protection
    RailsAiAdmin::ApplicationController.allow_forgery_protection = true
    patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: token, record: { name: "Attack" } }
    assert_response :unprocessable_content
    assert_equal "Alice", @customer.reload.name
  ensure
    RailsAiAdmin::ApplicationController.allow_forgery_protection = previous
  end

  def test_untrusted_payload_is_redacted_without_mutating_host_filters
    payload = nil
    original = Rails.application.config.filter_parameters.dup
    callback = ->(*args) { payload = args.last }
    ActiveSupport::Notifications.subscribed(callback, "start_processing.action_controller") do
      patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: "invented", record: { secret: "sensitive-user-submitted-value" }, unexpected: "injected-value" }
    end
    refute_includes payload[:params].to_json, "sensitive-user-submitted-value"
    refute_includes payload[:params].to_json, "injected-value"
    assert_equal original, Rails.application.config.filter_parameters
  end
  def test_started_request_url_redacts_search_and_unknown_values
    search = "raa-private-query-#{SecureRandom.hex(8)}"
    get "/backoffice/customers", params: { q: search, unexpected: "raa-private-extra" }
    assert_response :success
    lines = File.readlines(File.expand_path("../../log/test-#{Process.pid}.log", __dir__)).select { |line| line.include?('Started GET "/backoffice/customers?') }
    assert lines.any?
    refute_includes lines.last, search
    refute_includes lines.last, "raa-private-extra"
    assert_includes lines.last, "FILTERED"
  end
  def test_new_form_does_not_require_permission_to_show_an_unsaved_record
    TestPolicy.deny_show = true
    get "/backoffice/customers/new"
    assert_response :success
    assert_select "input[name='record[name]']"
  end

  def test_an_unsupported_scope_fails_closed_without_diagnostic_content
    TestPolicy.limited_scope = true
    get "/backoffice/customers"
    assert_response :service_unavailable
    refute_includes response.body, "Alice"
    refute_includes response.body, "LIMIT"
  end
  def test_relative_url_root_is_preserved_in_admin_links
    get "/backoffice/customers", env: { "SCRIPT_NAME" => "/portal" }
    assert_response :success
    assert_select "a[href='/portal/backoffice/customers/new']"
    assert_select "a[href='/portal/backoffice/customers/#{@customer.id}']"
  end
end
