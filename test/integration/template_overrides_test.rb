# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/operations"
require "generators/rails_ai_admin/override/override_generator"
require "tmpdir"

class NativeTemplateOverridesTest < ActionDispatch::IntegrationTest
  include DatabaseHelpers
  include OperationContractHelpers

  def setup
    reset_database
    post "/test/sign_in/1"
  end

  def with_overrides(keys, controller: RailsAiAdmin::ResourcesController)
    Dir.mktmpdir("raa-native-overrides-", File.expand_path("../../tmp", __dir__)) do |directory|
      root = Pathname.new(directory)
      catalog = RailsAiAdmin::Templates::Catalog.new
      keys.each do |key|
        capture_io { RailsAiAdmin::Generators::OverrideGenerator.new([ key ], {}, destination_root: directory).invoke_all }
        path = root.join("app/views", catalog.fetch(key).path)
        header, *lines = path.read.lines
        body = lines.join
        marker = if key == "layout"
          body.sub('<body class="raa">', '<body class="raa" data-host-override="layout">')
        elsif key.start_with?("field_")
          %(<span data-host-field="<%= field.name %>" data-host-override="#{key}">#{body}</span>)
        else
          %(<p data-host-override="#{key}">Host #{key}</p>\n#{body})
        end
        path.write(header + marker)
      end
      previous = controller.view_paths
      controller.prepend_view_path(root.join("app/views").to_s)
      yield root
    ensure
      controller.view_paths = previous if previous
    end
  end

  def intent = css_select("input[name=intent_ref]").first["value"]

  def test_distinct_new_edit_overrides_survive_validation_and_conflict_rerenders
    with_overrides(%w[resource_new resource_edit]) do
      get "/backoffice/customers/new"
      assert_response :success
      assert_select "[data-host-override=resource_new]"
      token = intent
      post "/backoffice/customers", params: { intent_ref: token, record: { name: "" } }
      assert_response :unprocessable_content
      assert_select "[data-host-override=resource_new]"
      get "/backoffice/customers/#{@customer.id}/edit"
      assert_select "[data-host-override=resource_edit]"
      token = intent
      patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: token, record: { name: "" } }
      assert_response :unprocessable_content
      assert_select "[data-host-override=resource_edit]"
      @customer.update!(name: "Concurrent update")
      patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: token, record: { name: "Stale update" } }
      assert_response :conflict
      assert_select "[data-host-override=resource_edit]"
      assert_select "input[type=submit][disabled]"
      assert_equal "Concurrent update", @customer.reload.name
    end
  end

  def test_host_layout_and_default_field_partial_lookup_keep_escaping_and_field_grants
    @customer.update!(name: "<script>private()</script>")
    with_overrides(%w[layout field_index field_show]) do
      get "/backoffice/customers"
      assert_response :success
      assert_select "[data-host-override=layout]"
      assert_select "[data-host-override=field_index][data-host-field=name]"
      assert_equal 1, response.body.scan(/<!DOCTYPE/i).size
      refute_includes response.body, "<script>private()</script>"
      assert_includes response.body, "&lt;script&gt;"
      get "/backoffice/customers/#{@customer.id}"
      assert_select "[data-host-override=field_show][data-host-field=name]"
      TestPolicy.hide_name = true
      get "/backoffice/customers/#{@customer.id}"
      assert_select "[data-host-field=name]", count: 0
      refute_includes response.body, "private()"
      refute_includes response.body, "never show"
    end
  end

  def test_overridden_new_and_field_form_keep_one_form_csrf_intent_and_server_write_boundary
    with_overrides(%w[layout resource_edit field_form]) do
      previous = RailsAiAdmin::ApplicationController.allow_forgery_protection
      RailsAiAdmin::ApplicationController.allow_forgery_protection = true
      get "/backoffice/customers/#{@customer.id}/edit"
      assert_response :success
      assert_select "form", count: 1
      assert_select "input[name=intent_ref]", count: 1
      assert_select "input[name=authenticity_token]", count: 1
      assert_select "form[data-controller~='raa-dirty-form']"
      assert_select "[data-host-override=field_form][data-host-field=name]"
      token = intent
      csrf = css_select("input[name=authenticity_token]").first["value"]
      patch "/backoffice/customers/#{@customer.id}", params: { intent_ref: token, record: { name: "Missing token" } }
      assert_response :unprocessable_content
      assert_equal "Alice", @customer.reload.name
      patch "/backoffice/customers/#{@customer.id}", params: { authenticity_token: csrf, intent_ref: token, record: { name: "Reviewed host form" } }
      assert_response :see_other
      assert_equal "Reviewed host form", @customer.reload.name
    ensure
      RailsAiAdmin::ApplicationController.allow_forgery_protection = previous
    end
  end

  def test_member_action_wrapper_override_preserves_review_and_single_execution
    with_operations do
      with_overrides(%w[operation_form operation_confirmation], controller: RailsAiAdmin::OperationsController) do
        path = "/backoffice/contract_customers/#{@customer.id}/operations/review"
        get path
        assert_response :success
        assert_select "[data-host-override=operation_form]"
        post "#{path}/preflight", params: { expected_version: 0, input: { note: "Reviewed through override" } }
        assert_response :success
        assert_select "[data-host-override=operation_confirmation]"
        assert_equal "Alice", @customer.reload.name
        params = { intent_ref: intent, confirmed_input: css_select("input[name=confirmed_input]").first["value"] }
        2.times { post "#{path}/execute", params: params; assert_response :see_other }
        assert_equal "Reviewed through override", @customer.reload.name
        assert_equal 1, @customer.lock_version
        assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
      end
    end
  end
end
