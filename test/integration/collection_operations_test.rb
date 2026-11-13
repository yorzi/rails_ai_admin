# frozen_string_literal: true

require "test_helper"
require "support/application"
require "support/collections"

class CollectionOperationsRequestsTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include DatabaseHelpers
  include CollectionContractHelpers

  def setup
    reset_database
    @second = Customer.create!(account_id: 1, name: "Second")
    post "/test/sign_in/1"
  end

  def native_proposal
    post "/backoffice/batch_customers/selections", params: { target_ids: [ @customer.id, @second.id ] }
    assert_response :see_other
    get URI(response.location).path
    assert_response :success
    link = css_select("a").find { |node| node["href"].include?("/operations/award?") }
    assert link
    get link["href"]
    assert_response :success
    @selection_ref = css_select("input[name=selection_ref]").first["value"]
    post "/backoffice/batch_customers/operations/award/preflight", params: {
      selection_ref: @selection_ref, input: { amount: "08", note: "Private approved input" } }
    assert_response :success
    { intent_ref: css_select("input[name=intent_ref]").first["value"],
      selection_ref: @selection_ref, confirmed_input: css_select("input[name=confirmed_input]").first["value"] }
  end

  def test_native_review_admission_current_results_and_independent_cancel
    with_collection do
      confirmation = native_proposal
      assert_select "input[type=submit][value='Confirm and queue']"
      assert_equal 0, RailsAiAdmin::BatchItem.count
      assert_equal 0, @customer.reload.points
      post "/backoffice/batch_customers/operations/award/execute", params: confirmation
      assert_response :see_other
      path = URI(response.location).path
      get path
      assert_response :success
      assert_includes response.body, "Queued"
      refute_includes response.body, "Private approved input"
      assert_equal 0, @customer.reload.points
      assert_select "button", text: "Cancel remaining items"
      RailsAiAdmin::Collections::Dispatcher.new.run(confirmation[:intent_ref], limit: 1)
      post "#{path}/cancel"
      assert_response :see_other
      get path
      assert_response :success
      assert_includes response.body, "Partially succeeded"
      assert_equal [ 0, 8 ], [ @customer.reload.points, @second.reload.points ].sort
      post "/backoffice/batch_customers/operations/award/execute", params: confirmation
      assert_response :see_other
      assert_equal 2, RailsAiAdmin::BatchItem.count
      assert_equal 1, RailsAiAdmin::AuditEvent.where(status: "succeeded").count
    end
  end

  def test_native_binding_anonymous_direct_child_and_receipt_revocation_are_closed
    with_collection do
      confirmation = native_proposal
      foreign_selection = selection([ @second.id ])
      post "/backoffice/batch_customers/operations/award/execute", params: confirmation.merge(selection_ref: foreign_selection.selection_ref)
      assert_response :not_found
      assert_empty RailsAiAdmin::BatchItem.all
      post "/backoffice/batch_customers/operations/award/execute", params: confirmation
      path = URI(response.location).path
      child = RailsAiAdmin::OperationRun.where(parent_run_id: confirmation[:intent_ref]).first
      post "/backoffice/batch_customers/#{child.target_id}/operations/award/execute", params: { intent_ref: child.id, confirmed_input: confirmation[:confirmed_input] }
      assert_response :not_found
      assert_equal 0, @customer.reload.points
      anonymous = open_session
      anonymous.get path
      assert_equal 401, anonymous.response.status
      post "/test/sign_in/2"
      get path
      assert_response :not_found
      post "/test/sign_in/1"
      CollectionContractPolicy.receipt_grant = false
      get path
      assert_response :not_found
      refute_includes response.body, "Alice"
    end
  end

  def test_native_queue_post_requires_csrf_and_rejects_changed_input
    with_collection do
      confirmation = native_proposal
      previous = RailsAiAdmin::ApplicationController.allow_forgery_protection
      RailsAiAdmin::ApplicationController.allow_forgery_protection = true
      post "/backoffice/batch_customers/operations/award/execute", params: confirmation
      assert_response :unprocessable_content
      assert_empty RailsAiAdmin::BatchItem.all
      RailsAiAdmin::ApplicationController.allow_forgery_protection = previous
      post "/backoffice/batch_customers/operations/award/execute", params: confirmation.merge(confirmed_input: '{"amount":9,"note":"Private approved input"}')
      assert_response :conflict
      assert_empty RailsAiAdmin::BatchItem.all
      assert_equal 0, @customer.reload.points
    ensure
      RailsAiAdmin::ApplicationController.allow_forgery_protection = previous
    end
  end

  def test_job_records_and_titles_are_filtered_under_current_scope_and_fields
    with_collection do
      accepted = admit
      get "/backoffice/jobs/#{accepted.job_ref}"
      assert_response :success
      assert_includes response.body, "Alice"
      # A backlog older than five minutes names the queue as code, not escaped text.
      RailsAiAdmin::BatchItem.where(parent_run_id: accepted.job_ref).update_all(created_at: 10.minutes.ago)
      get "/backoffice/jobs/#{accepted.job_ref}"
      assert_select ".raa-notice code", text: RailsAiAdmin.configuration.queue_name
      refute_includes response.body, "&lt;code&gt;"
      @customer.update!(account_id: 2)
      get "/backoffice/jobs/#{accepted.job_ref}"
      assert_response :success
      refute_includes response.body, "Alice"
      assert_includes response.body, "not currently visible"
      TestPolicy.hide_name = true
      get "/backoffice/jobs/#{accepted.job_ref}"
      assert_response :success
      refute_includes response.body, "Second"
      assert_includes response.body, "Record ##{@second.id}"
      get "/backoffice/jobs"
      assert_response :success
      assert_select "a[href='/backoffice/jobs/#{accepted.job_ref}']"
    end
  end
  def test_job_projection_diagnostics_are_not_exposed_in_http
    with_collection do
      accepted = admit
      CollectionContractPolicy.read_hook = -> { raise "synthetic private projection diagnostic" }
      get "/backoffice/jobs/#{accepted.job_ref}"
      assert_response :service_unavailable
      refute_includes response.body, "synthetic private projection diagnostic"
    end
  end
end
