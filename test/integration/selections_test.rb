# frozen_string_literal: true

require "test_helper"
require "support/application"
require "minitest/mock"

class NativeSelectionPolicy < TestPolicy
  def select_records?(context:, resource:) = context.actor.id == 1
end

class NativeSelectionsTest < ActionDispatch::IntegrationTest
  include DatabaseHelpers

  def setup
    reset_database
    post "/test/sign_in/1"
  end

  def with_policy
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = "NativeSelectionPolicy"
    RailsAiAdmin.stub(:configuration, config) { yield }
  end

  def test_native_selection_posts_redirects_and_rechecks_exact_current_targets
    with_policy do
      get "/backoffice/customers"
      assert_select "form#raa-selection[action='/backoffice/customers/selections'][method=post]"
      assert_select "input[name='target_ids[]'][value='#{@customer.id}'][form='raa-selection']"
      assert_empty css_select("input[name='target_ids[]'][value='#{@other.id}']")
      post "/backoffice/customers/selections", params: { target_ids: [ @customer.id ] }
      assert_response :see_other
      path = URI(response.location).path
      get path
      assert_response :success
      assert_includes response.body, "1 fixed target"
      assert_includes response.body, "Alice"
      refute_includes response.body, "never show"
      assert_empty RailsAiAdmin::OperationRun.all
      assert_empty RailsAiAdmin::AuditEvent.all
      assert_includes response.headers["Cache-Control"], "no-store"
      @customer.update!(name: "Changed confidential label")
      get path
      assert_response :conflict
      refute_includes response.body, "Changed confidential label"
      assert_equal 1, RailsAiAdmin::SelectionItem.count
    end
  end

  def test_no_implicit_grant_and_no_cross_actor_or_tenant_access
    get "/backoffice/customers"
    assert_empty css_select("form#raa-selection")
    post "/backoffice/customers/selections", params: { target_ids: [ @customer.id ] }
    assert_response :not_found
    with_policy do
      post "/backoffice/customers/selections", params: { target_ids: [ @other.id ] }
      assert_response :not_found
      post "/backoffice/customers/selections", params: { target_ids: [ @customer.id ] }
      path = URI(response.location).path
      post "/test/sign_in/2"
      get path
      assert_response :not_found
      anonymous = open_session
      anonymous.get path
      assert_equal 401, anonymous.response.status
    end
  end

  def test_csrf_malformed_and_expired_capture_are_closed
    with_policy do
      previous = RailsAiAdmin::ApplicationController.allow_forgery_protection
      RailsAiAdmin::ApplicationController.allow_forgery_protection = true
      post "/backoffice/customers/selections", params: { target_ids: [ @customer.id ] }
      assert_response :unprocessable_content
      assert_empty RailsAiAdmin::Selection.all
      RailsAiAdmin::ApplicationController.allow_forgery_protection = previous
      post "/backoffice/customers/selections", params: { target_ids: "all" }
      assert_response :unprocessable_content
      post "/backoffice/customers/selections", params: { target_ids: [ @customer.id ] }
      path = URI(response.location).path
      RailsAiAdmin::Selection.update_all(expires_at: 1.second.ago)
      get path
      assert_response :conflict
      refute_includes response.body, "Alice"
    ensure
      RailsAiAdmin::ApplicationController.allow_forgery_protection = previous
    end
  end

  def test_labels_are_escaped_and_masked_after_field_revocation
    with_policy do
      @customer.update!(name: '<script>alert("selection")</script>')
      post "/backoffice/customers/selections", params: { target_ids: [ @customer.id ] }
      path = URI(response.location).path
      get path
      assert_response :success
      refute_includes response.body, '<script>alert("selection")</script>'
      assert_includes response.body, "&lt;script&gt;"
      TestPolicy.hide_name = true
      get path
      assert_response :success
      refute_includes response.body, "&lt;script&gt;"
      assert_includes response.body, "Record ##{@customer.id}"
    end
  end
end
