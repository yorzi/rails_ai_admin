# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/operations"

class OperationsRequestsTest < ActionDispatch::IntegrationTest
  include DatabaseHelpers
  include OperationContractHelpers

  def setup
    reset_database
    post "/test/sign_in/1"
  end

  def operation_path(action = nil, id: @customer.id)
    "/backoffice/contract_customers/#{id}/operations/review#{action && "/#{action}"}"
  end

  def review_input(value = "Reviewed via form")
    post operation_path("preflight"), params: { expected_version: @customer.lock_version, input: { note: value } }
    assert_response :success
    { intent_ref: css_select("input[name=intent_ref]").first["value"], confirmed_input: css_select("input[name=confirmed_input]").first["value"] }
  end

  def test_native_form_preview_confirmation_and_same_intent_replay
    with_operations do
      get "/backoffice/contract_customers/#{@customer.id}"
      assert_response :success
      assert_select "a[href='#{operation_path}']"
      get operation_path
      assert_response :success
      assert_select "input[name='input[note]']"
      refute css_select("input[name=intent_ref]").any?
      confirmation = review_input
      assert_equal "Alice", @customer.reload.name
      refute_includes response.body, "never expose this preview"
      assert_select "input[name=confirmed_input]"
      post operation_path("execute"), params: confirmation
      assert_response :see_other
      assert_equal "Reviewed via form", @customer.reload.name
      assert_equal 1, RailsAiAdmin::WorkItem.count
      post operation_path("execute"), params: confirmation
      assert_response :see_other
      assert_equal 1, @customer.reload.lock_version
      assert_equal 1, RailsAiAdmin::WorkItem.count
    end
  end

  def test_changed_confirmation_foreign_target_and_revoked_input_are_rejected
    with_operations do
      confirmation = review_input
      changed = confirmation.merge(confirmed_input: JSON.generate(note: "Unreviewed change"))
      post operation_path("execute"), params: changed
      assert_response :conflict
      post operation_path("execute", id: @other.id), params: confirmation
      assert_response :not_found
      OperationContractPolicy.input_grant = false
      post operation_path("execute"), params: confirmation
      assert_response :not_found
      assert_equal "Alice", @customer.reload.name
      assert_empty RailsAiAdmin::WorkItem.all
    end
  end

  def test_turbo_preflight_stream_replaces_the_confirmation_region
    with_operations do
      get operation_path
      flow_id = css_select("div[id^=raa_operation_]").first["id"]
      post operation_path("preflight"), params: { expected_version: @customer.lock_version, input: { note: "Reviewed with Turbo" } },
        headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }
      assert_response :success
      assert_equal "text/vnd.turbo-stream.html", response.media_type
      assert_select "turbo-stream[action=replace][target='#{flow_id}']"
      assert_select "template div[id='#{flow_id}'] input[name=confirmed_input]"
      assert_equal "Alice", @customer.reload.name
    end
  end

  def test_preview_escapes_input_and_rejects_undeclared_parameters
    with_operations do
      review_input("<script>alert('x')</script>")
      refute_includes response.body, "<script>alert('x')</script>"
      assert_includes response.body, "&lt;script&gt;"
      post operation_path("preflight"), params: { expected_version: 0, input: { note: "ok", secret: "forbidden" } }
      assert_response :unprocessable_content
      refute_includes response.body, "forbidden"
      assert_equal "Alice", @customer.reload.name
    end
  end

  def test_unexpected_preview_errors_never_escape_to_http_or_controller_logs
    with_operations do
      output = StringIO.new
      previous_logger = ActionController::Base.logger
      ActionController::Base.logger = ActiveSupport::Logger.new(output)
      post "/backoffice/contract_customers/#{@customer.id}/operations/failing_preview/preflight",
        params: { expected_version: @customer.lock_version, input: { note: "reviewed input" } }
      assert_response :service_unavailable
      refute_includes response.body, "sensitive preview diagnostic"
      refute_includes output.string, "sensitive preview diagnostic"
      assert_empty RailsAiAdmin::OperationRun.all
      assert_empty RailsAiAdmin::WorkItem.all
      assert_equal "Alice", @customer.reload.name
    ensure
      ActionController::Base.logger = previous_logger
    end
  end
end
