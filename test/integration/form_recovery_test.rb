# frozen_string_literal: true

require "test_helper"
require "support/application"
require "minitest/mock"

class NativeFormRecoveryTest < ActionDispatch::IntegrationTest
  include DatabaseHelpers

  class NarrowedPolicy < TestPolicy
    def fields(**options)
      options[:action] == :write ? super - [ :points ] : super
    end
  end

  def setup
    reset_database
    post "/test/sign_in/1"
  end

  def intent = css_select("input[name=intent_ref]").first["value"]
  def recover(ref)
    get "/backoffice/customers/forms/recover", headers: { "X-RailsAiAdmin-Recovery-Intent" => ref }
  end

  def test_recovery_requires_current_authentication_and_a_header_never_query_or_body_binding
    get "/backoffice/customers/#{@customer.id}/edit"
    token = intent
    guest = open_session
    guest.get "/backoffice/customers/forms/recover", headers: { "X-RailsAiAdmin-Recovery-Intent" => token }
    assert_equal 401, guest.response.status
    assert_includes guest.response.headers["Cache-Control"], "no-store"
    get "/backoffice/customers/forms/recover", params: { intent_ref: token }
    assert_response :not_found
    refute_includes response.body, "Alice"
    recover(token)
    assert_response :success
    assert_equal token, intent
    assert_equal "ready", response.headers["X-RailsAiAdmin-Form-Recovery"]
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_includes response.headers["Vary"], "X-RailsAiAdmin-Recovery-Intent"
    assert_select "form[data-controller~='raa-form-recovery']"
    assert_equal 1, RailsAiAdmin::OperationRun.count
    assert_equal "Alice", @customer.reload.name
    assert_empty RailsAiAdmin::AuditEvent.all
  end

  def test_unauthenticated_write_and_csrf_failure_are_marked_but_validation_is_not
    get "/backoffice/customers/#{@customer.id}/edit"
    token = intent
    guest = open_session
    guest.patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: token, record: { name: "Must not execute" } }
    assert_equal 401, guest.response.status
    assert_equal "session", guest.response.headers["X-RailsAiAdmin-Form-Recovery"]
    previous = RailsAiAdmin::ApplicationController.allow_forgery_protection
    RailsAiAdmin::ApplicationController.allow_forgery_protection = true
    patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: token, record: { name: "Must not execute" } }
    assert_response :unprocessable_content
    assert_equal "session", response.headers["X-RailsAiAdmin-Form-Recovery"]
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_includes response.headers["Content-Security-Policy"], "default-src 'self'"
    RailsAiAdmin::ApplicationController.allow_forgery_protection = false
    patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: token, record: { name: "" } }
    assert_response :unprocessable_content
    assert_nil response.headers["X-RailsAiAdmin-Form-Recovery"]
    assert_select ".raa-errors"
    assert_equal "Alice", @customer.reload.name
  ensure
    RailsAiAdmin::ApplicationController.allow_forgery_protection = previous
  end

  def test_recovery_does_not_return_removed_fields_or_retarget_a_stale_form
    get "/backoffice/customers/#{@customer.id}/edit"
    token = intent
    TestPolicy.hide_name = true
    recover(token)
    assert_response :success
    assert_select "input[name='record[name]']" do |nodes|
      assert_includes [ nil, "" ], nodes.first["value"]
    end
    refute_includes response.body, "Alice"
    @customer.update!(points: 10)
    recover(token)
    assert_response :conflict
    assert_nil response.headers["X-RailsAiAdmin-Form-Recovery"]
    refute_includes response.body, "Alice"
    assert_equal 10, @customer.reload.points
  end

  def test_recovery_rebuilds_current_writable_fields_and_only_fresh_readonly_context
    get "/backoffice/customers/#{@customer.id}/edit"
    token = intent
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = "NativeFormRecoveryTest::NarrowedPolicy"
    RailsAiAdmin.stub(:configuration, config) { recover(token) }
    assert_response :success
    assert_select "input[name='record[points]']", count: 0
    assert_select ".raa-readonly", text: "0"
    form = css_select("form[data-raa-form-recovery-fields-value]").first
    assert_equal %w[name active], JSON.parse(form["data-raa-form-recovery-fields-value"])
    assert_equal 0, @customer.reload.points
    assert_equal token, intent
  end

  def test_a_rendering_failure_never_advertises_a_ready_recovery_form
    get "/backoffice/customers/#{@customer.id}/edit"
    token = intent
    RailsAiAdmin::FieldsHelper.module_eval do
      alias_method :original_recovery_admin_field_value, :admin_field_value
      remove_method :admin_field_value
      define_method(:admin_field_value) { |*args, **kwargs| raise RailsAiAdmin::ConfigurationError, "Private rendering diagnostic" }
    end
    recover(token)
    assert_response :service_unavailable
    assert_nil response.headers["X-RailsAiAdmin-Form-Recovery"]
    refute_includes response.body, "Private rendering diagnostic"
    assert_equal "Alice", @customer.reload.name
  ensure
    RailsAiAdmin::FieldsHelper.module_eval do
      if method_defined?(:original_recovery_admin_field_value)
        remove_method :admin_field_value
        alias_method :admin_field_value, :original_recovery_admin_field_value
        remove_method :original_recovery_admin_field_value
      end
    end
  end

  def test_recovery_never_returns_another_actor_or_tenant_form
    get "/backoffice/customers/#{@customer.id}/edit"
    token = intent
    post "/test/sign_in/2"
    recover(token)
    assert_response :not_found
    refute_includes response.body, "Alice"
    assert_select "form", count: 0
  end
end
