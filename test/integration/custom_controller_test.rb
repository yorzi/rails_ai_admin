# frozen_string_literal: true

require "test_helper"
require "support/application"
require "minitest/mock"
require "tmpdir"

class CustomControllerTest < ActionDispatch::IntegrationTest
  include DatabaseHelpers

  def setup
    reset_database
    post "/test/sign_in/1"
  end

  def test_host_and_engine_routes_keep_their_own_helpers_in_a_normal_controller_and_partial
    [ "/host/customers/#{@customer.id}", "/backoffice/custom/customers/#{@customer.id}" ].each do |path|
      get path
      assert_response :success
      assert_select "h1", text: "Host custom page"
      assert_select "[data-host-card]", text: "Alice"
      assert_select "a[data-host-root][href='/']"
      assert_equal "/backoffice/customers/#{@customer.id}", css_select("a[data-engine-record]").first["href"]
      refute_includes response.body, "never show"
      assert_includes response.headers["Cache-Control"], "no-store"
    end
    get "/backoffice/custom/customers/#{@customer.id}", env: { "SCRIPT_NAME" => "/portal" }
    assert_response :success
    assert_select "a[data-host-root][href='/portal/']"
    assert_select "a[data-engine-record][href='/portal/backoffice/customers/#{@customer.id}']"
  end

  def test_scoped_lookup_and_field_projection_remain_required_in_host_pages
    get "/backoffice/custom/customers/#{@other.id}"
    assert_response :not_found
    refute_includes response.body, "Other tenant"
    TestPolicy.hide_name = true
    get "/backoffice/custom/customers/#{@customer.id}"
    assert_response :success
    refute_includes response.body, "Alice"
    guest = open_session
    guest.get "/backoffice/custom/customers/#{@customer.id}"
    assert_equal 401, guest.response.status
    refute_includes guest.response.body, "Alice"
  end

  def test_normal_host_posts_use_csrf_and_the_shared_runner_with_explicit_route_binding
    get "/backoffice/custom/customers/#{@customer.id}/prepare"
    assert_response :success
    ref = response.body
    previous = RailsAiAdmin::ApplicationController.allow_forgery_protection
    RailsAiAdmin::ApplicationController.allow_forgery_protection = true
    post "/backoffice/custom/customers/#{@customer.id}/save", params: { intent_ref: ref, record: { name: "Denied CSRF" } }
    assert_response :unprocessable_content
    assert_equal "Alice", @customer.reload.name
    RailsAiAdmin::ApplicationController.allow_forgery_protection = false
    post "/backoffice/custom/customers/#{@other.id}/save", params: { intent_ref: ref, record: { name: "Wrong target" } }
    assert_response :not_found
    assert_equal "Alice", @customer.reload.name
    2.times do
      post "/backoffice/custom/customers/#{@customer.id}/save", params: { intent_ref: ref, record: { name: "Host changed through runner" } }
      assert_response :success
    end
    assert_equal "Host changed through runner", @customer.reload.name
    assert_equal 1, @customer.lock_version
    assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
  ensure
    RailsAiAdmin::ApplicationController.allow_forgery_protection = previous
  end

  def test_public_extension_helpers_are_protected_not_extra_routable_actions
    %w[admin_context admin_access admin_routes admin_operation_runner admin_status admin_csp_nonce].each do |name|
      refute_includes CustomAdminPagesController.action_methods, name
      assert CustomAdminPagesController.protected_instance_methods.include?(name.to_sym)
    end
  end

  def test_status_pages_are_fixed_safe_html_with_turbo_reload_and_plain_non_html
    get "/backoffice/custom/status/forbidden", headers: { "Accept" => "text/vnd.turbo-stream.html, text/html", "Turbo-Frame" => "untrusted-frame-content" }
    assert_response :forbidden
    assert_equal "text/html", response.media_type
    assert_select "meta[name=turbo-visit-control][content=reload]"
    assert_select "h1", text: "Access unavailable"
    assert_select "nav", count: 0
    refute_includes response.body, "untrusted-frame-content"
    refute_includes response.body, "Alice"
    assert_includes response.headers["Content-Security-Policy"], "default-src 'self'"
    get "/backoffice/custom/status/error"
    assert_response :internal_server_error
    assert_includes response.body, "may have completed"
    get "/backoffice/custom/status/unknown", headers: { "Accept" => "application/json" }
    assert_response :not_found
    assert_equal "text/plain", response.media_type
    refute_includes response.body, "private unknown error code"
  end

  def test_configuration_status_does_not_render_normal_resource_policy_navigation
    policy = TestPolicy.new
    policy.define_singleton_method(:allowed?) { |**| raise RailsAiAdmin::ConfigurationError, "private policy diagnostic" }
    TestPolicy.stub(:new, policy) do
      get "/backoffice/customers"
      assert_response :service_unavailable
      assert_select "h1", text: "Administration unavailable"
      refute_includes response.body, "private policy diagnostic"
      assert_select "nav", count: 0
    end
  end

  def test_a_broken_host_status_override_falls_back_without_changing_the_status_or_diagnostic_boundary
    Dir.mktmpdir("raa-status-", File.expand_path("../../tmp", __dir__)) do |directory|
      path = Pathname.new(directory).join("rails_ai_admin/statuses/show.html.erb")
      path.dirname.mkpath
      path.write('<% raise "private failed status template" %>')
      previous = CustomAdminPagesController.view_paths
      CustomAdminPagesController.prepend_view_path(directory)
      get "/backoffice/custom/status/forbidden"
      assert_response :forbidden
      assert_equal "text/plain", response.media_type
      assert_equal RailsAiAdmin::Presentation::Status.fetch(:forbidden).message, response.body
      refute_includes response.body, "private failed status template"
    ensure
      CustomAdminPagesController.view_paths = previous if previous
    end
  end

  def test_unknown_action_exceptions_still_belong_to_host_exception_handling
    error = assert_raises(StandardError) { get "/backoffice/custom/status/broken" }
    assert_instance_of StandardError, error
    assert_equal "Unhandled action failures remain visible to host exception handling", error.message
  end
end
